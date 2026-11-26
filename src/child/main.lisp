(in-package #:task-worker-process/child)

;;; 0.1.0 child entry point (contract).
;;;
;;; The parent writes, in a fresh job directory D:
;;;   D/request.sexp   one readable plist (FRAME-STRING syntax):
;;;                    (:job-id ID :kind KIND :payload PAYLOAD
;;;                     :handler "PKG::NAME" :systems ("sys" …))
;;;   D/boot.lisp      the forms the child command LOADs; the last one
;;;                    calls (CHILD-MAIN D)
;;; and launches the child with its stdout and stderr on D/child.log.
;;;
;;; CHILD-MAIN, in order:
;;;  1. reads D/request.sexp (*READ-EVAL* NIL, standard syntax);
;;;  2. opens D/channel for (UNSIGNED-BYTE 8) output, appending;
;;;  3. loads each of SYSTEMS with ASDF:LOAD-SYSTEM, in order;
;;;  4. reads HANDLER with *READ-EVAL* NIL and *PACKAGE* CL-USER (so the
;;;     designator names its package) and takes its FDEFINITION;
;;;  5. calls (handler PAYLOAD :report-progress RP :cancel-requested-p CP):
;;;       RP = (lambda (&key phase fraction message) …) writes a :progress
;;;            frame and returns NIL. FRACTION must be NIL or a real in
;;;            [0, 1], else RP signals TYPE-ERROR in the handler (nothing
;;;            written), which the handler may handle.
;;;       CP = (lambda () …) → T once D/cancel exists (the parent creates
;;;            it on a cancel request), else NIL.
;;;  6. writes (:result VALUE) and exits with code 0.
;;; Any SERIOUS-CONDITION escaping steps 3–6 (an ERROR, heap exhaustion,
;;; a stack exhaustion, a PRINT-NOT-READABLE result) is written as one
;;; :error frame (see channel.lisp) and the child exits with code 1. A
;;; request that cannot be read exits with code 2 and writes no frame.
;;; The child exits with UIOP:QUIT and FINISH-OUTPUT NIL, after it has
;;; finished its own output: threads a handler left running do not delay
;;; the exit. Nothing is caught that does not unwind (an abort exit from the
;;; handler, a fatal runtime error): those reach the parent as an exit code
;;; and the log.

(defun %read-request (pathname)
  "The request plist in PATHNAME (frame syntax, *READ-EVAL* NIL)."
  (with-open-file (in pathname :external-format :utf-8)
    (%with-frame-syntax (read in))))

(defun %heap-exhausted-p (condition)
  "T for heap exhaustion (SBCL: SB-KERNEL::HEAP-EXHAUSTED-ERROR). Not every
   STORAGE-CONDITION: a control stack exhaustion is a handler error."
  #+sbcl (let ((type (find-symbol "HEAP-EXHAUSTED-ERROR" "SB-KERNEL")))
           (and type (typep condition type) t))
  #-sbcl (typep condition 'storage-condition))

(defun %error-frame (condition)
  "The :error frame for CONDITION (see channel.lisp)."
  (let ((type (%with-frame-syntax
                (prin1-to-string (class-name (class-of condition)))))
        (message (handler-case (princ-to-string condition)
                   ;; a report that fails must not lose the frame
                   (error () nil))))
    (list :error :type type
                 :message (or message (format nil "<unprintable ~a>" type))
                 :heap-exhausted (%heap-exhausted-p condition))))

(defun %run-request (request directory channel)
  "Steps 3–5 of CHILD-MAIN. → the handler's value."
  (destructuring-bind (&key handler systems payload &allow-other-keys) request
    (mapc #'asdf:load-system systems)
    (let* ((name (with-standard-io-syntax
                   (let ((*package* (find-package '#:cl-user))
                         (*read-eval* nil))
                     (read-from-string handler))))
           (function (fdefinition name))
           (cancel-file (merge-pathnames +cancel-file+ directory)))
      (funcall function payload
               :report-progress
               (lambda (&key phase fraction message)
                 (check-type fraction (or null (real 0 1)))
                 (write-frame (list :progress :phase phase :fraction fraction
                                              :message message)
                              channel)
                 nil)
               :cancel-requested-p
               (lambda () (and (probe-file cancel-file) t))))))

(defun %flush-standard-streams ()
  (dolist (s (list *standard-output* *error-output*))
    (handler-case (finish-output s)
      (stream-error () nil))))

(defun child-main (directory)
  "Run the job described in DIRECTORY (see the file header) and exit the
   process. Never returns."
  (let* ((directory (uiop:ensure-directory-pathname directory))
         (request (handler-case (%read-request (merge-pathnames +request-file+ directory))
                    ;; unreadable request: exit 2, no frame
                    ((or file-error reader-error end-of-file) ()
                      (%flush-standard-streams)
                      (uiop:quit 2 nil))))
         (code 1))
    (with-open-file (channel (merge-pathnames +channel-file+ directory)
                             :direction :output :element-type '(unsigned-byte 8)
                             :if-exists :append :if-does-not-exist :create)
      (let ((frame (handler-case (list :result (%run-request request directory channel))
                     ;; HANDLER-CASE, not HANDLER-BIND: the handler's stack
                     ;; (and a heap hoard) is unwound before the frame is made.
                     (serious-condition (c) (%error-frame c)))))
        (handler-case
            (progn (write-frame frame channel)
                   (when (eq :result (first frame)) (setf code 0)))
          ;; an unreadable result: WRITE-FRAME wrote nothing
          (print-not-readable (c)
            (write-frame (%error-frame c) channel)))))
    (%flush-standard-streams)
    (uiop:quit code nil)))
