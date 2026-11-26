(in-package #:task-worker-process/tests)

;;; 0.1.0 contract: shared helpers.
;;;
;;; Conventions (CL / Rove pitfalls this suite avoids):
;;; - Conditions are caught or handled OUTSIDE Rove's OK, whose own ERROR
;;;   handler would otherwise run first; OK only sees plain values.
;;; - Restarts are looked up INSIDE the handler, by name, without the
;;;   condition argument.
;;; - Specials are not relied on across threads: job threads and helper
;;;   threads only touch closed-over variables.
;;; - Cleanup never depends on the test passing: every supervisor made with
;;;   %SUPERVISOR is stopped (grace 0) and every pid a child reported is
;;;   SIGKILLed in the after-test hook.
;;;
;;; Children are real SBCLs started by the default child command. Their
;;; ASDF registry is the test image's (cl-repo's project registry), so they
;;; find the fixture handler system in tests/fixtures/. Child heaps are
;;; small (256 / 384 / 512 MB).

(defparameter *fixture-system* "task-worker-process-test-handlers")

(defparameter *tiny-mb* 256)
(defparameter *small-mb* 384)
(defparameter *default-mb* 512)

(defun %h (name)
  "The fixture handler designator for NAME."
  (format nil "TWP-TEST-HANDLERS::~:@(~a~)" name))

(defun %queue (&rest resource-classes)
  "A fresh in-memory queue with RESOURCE-CLASSES ((NAME LIMIT) …), default
   :TINY and :SMALL, 4 each."
  (q:make-in-memory-job-queue
   :resource-classes (or resource-classes '((:tiny 4) (:small 4)))))

(defun %registry (&rest overrides)
  "A registry with every fixture handler, kind = keyword of the handler
   name. OVERRIDES: (KIND &rest define-job-handler keys) lists applied
   after, e.g. (:sleep :timeout 2)."
  (let ((r (w:make-handler-registry)))
    (dolist (entry '((:echo echo) (:progress progress)
                     (:sleep report-pid-and-sleep) (:cooperative cooperative)
                     (:hog hog) (:crash crash) (:fail fail)
                     (:slow slow-echo) (:heap-size heap-size)))
      (destructuring-bind (kind name) entry
        (w:define-job-handler r kind (%h name) :systems (list *fixture-system*))))
    (dolist (o overrides r)
      (destructuring-bind (kind &rest keys) o
        (let ((h (w:find-job-handler r kind)))
          (apply #'w:define-job-handler r kind (w:job-handler-function h)
                 :systems (w:job-handler-systems h) keys))))))

(defvar *test-work-root*
  (merge-pathnames (format nil "twp-tests-~36r/" (random (expt 36 8) (make-random-state t)))
                   (uiop:temporary-directory)))

(defvar *supervisors* '() "Supervisors made by %SUPERVISOR in this test.")
(defvar *pids* '() "Child pids seen in this test.")
(defvar *cleanup-lock* (bt:make-lock "twp test cleanup"))

(defun %supervisor (queue &rest keys &key (registry (%registry)) &allow-other-keys)
  "A supervisor over QUEUE with test defaults (short polls, small heaps,
   cancel grace 1 s, a per-run work directory); KEYS override them. Stopped
   after the test."
  (let ((keys (copy-list keys)))
    (remf keys :registry)
    (let ((s (apply #'w:make-process-supervisor queue registry
                    (append keys
                            (list :poll-interval 0.05
                                  :claim-interval 0.1
                                  :heap-sizes `((:tiny . ,*tiny-mb*)
                                                (:small . ,*small-mb*))
                                  :default-heap-mb *default-mb*
                                  :cancel-grace 1
                                  :work-directory *test-work-root*)))))
      (bt:with-lock-held (*cleanup-lock*) (push s *supervisors*))
      s)))

(defun %pid-alive-p (pid)
  (zerop (stack-process:run (list "kill" "-0" (princ-to-string pid))
                            :output nil :error-output nil)))

(defun %note-pid (pid)
  (bt:with-lock-held (*cleanup-lock*) (pushnew pid *pids*))
  pid)

(defun %cleanup ()
  (let ((sups (bt:with-lock-held (*cleanup-lock*) (shiftf *supervisors* '())))
        (pids (bt:with-lock-held (*cleanup-lock*) (shiftf *pids* '()))))
    (dolist (s sups)
      (handler-case (w:stop-supervisor s :grace 0 :wait t)
        (error () nil)))
    (dolist (pid pids)
      (handler-case (stack-process:run (list "kill" "-9" (princ-to-string pid))
                                       :output nil :error-output nil)
        (error () nil)))))

(defhook cleanup-children :after
  (%cleanup))

(defun %wait-until (thunk &key (timeout 60) (interval 0.05))
  "Poll THUNK until it returns true (→ its value) or TIMEOUT seconds pass
   (→ NIL)."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (let ((v (funcall thunk)))
        (when v (return v)))
      (when (> (get-internal-real-time) deadline) (return nil))
      (sleep interval))))

(defun %gone-p (pid)
  "T once PID no longer exists (waits up to 10 s)."
  (and (%wait-until (lambda () (not (%pid-alive-p pid))) :timeout 10) t))

(defun %state (queue id)
  (q:job-state (q:job-status queue id)))

(defun %failure (queue id)
  (let ((f (q:job-failure (q:job-status queue id))))
    (if (stringp f) f (princ-to-string f))))

(defun %contains (string &rest parts)
  (every (lambda (p) (search p string)) parts))

(defun %progress (queue id)
  (remove-if-not #'q:job-progress-p (q:job-events queue id)))

(defun %wait-for-pid (queue id &key (timeout 60))
  "The pid a fixture handler reported for job ID (a \"pid\" progress
   event), noted for cleanup; NIL after TIMEOUT seconds."
  (let ((pid (%wait-until
              (lambda ()
                (let ((e (find "pid" (%progress queue id)
                               :key #'q:job-progress-phase :test #'equal)))
                  (and e (parse-integer (q:job-progress-message e)))))
              :timeout timeout)))
    (and pid (%note-pid pid))))

(defun %spawn (thunk)
  "Run THUNK in a new thread. → a function of no arguments that waits (up
   to 120 s) for the thread and returns (values THUNK's value, the ERROR it
   signalled or NIL, T when it finished)."
  (let ((value nil) (err nil) (done nil))
    (let ((thread (bt:make-thread
                   (lambda ()
                     (handler-case (setf value (funcall thunk))
                       (error (c) (setf err c)))
                     (setf done t))
                   :name "twp-test helper")))
      (lambda ()
        (%wait-until (lambda () done) :timeout 120)
        (when done (bt:join-thread thread))
        (values value err done)))))

(defun %catch (thunk)
  "The ERROR THUNK signals, or NIL when it returns normally."
  (handler-case (progn (funcall thunk) nil)
    (error (c) c)))

(defun %sh (script)
  "A LISP-COMMAND that ignores its arguments and runs /bin/sh -c SCRIPT
(Unix only: the signal test)."
  (lambda (heap-mb boot-file)
    (declare (ignore heap-mb boot-file))
    (list "/bin/sh" "-c" script)))

(defun %fake-argv (&key say (code 0))
  "Argv of a fake child, portable: this image's SBCL (runtime and core) that
prints SAY (when given) to its stdout and exits with CODE, loading nothing."
  (list (namestring sb-ext:*runtime-pathname*)
        "--core" (namestring sb-ext:*core-pathname*)
        "--noinform" "--non-interactive" "--no-sysinit" "--no-userinit"
        "--eval" (format nil "(progn ~@[(write-line ~S) ~](finish-output) (sb-ext:exit :code ~D :abort t))"
                         say code)))

(defun %fake (&key say (code 0))
  "A LISP-COMMAND that ignores its arguments and runs %FAKE-ARGV."
  (lambda (heap-mb boot-file)
    (declare (ignore heap-mb boot-file))
    (%fake-argv :say say :code code)))

(defun %submit (queue kind &rest keys)
  (apply #'q:submit-job queue kind keys))
