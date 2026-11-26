(in-package #:task-worker-process)

;;; 0.1.0 process supervisor (class given, operations contract). This file
;;; header is the spec; tests/ grade it.
;;;
;;; What it does
;;; ------------
;;; A PROCESS-SUPERVISOR claims jobs from a task-protocol 0.3 JOB-QUEUE (any
;;; backend: the in-memory queue, task-backend-sql's SQL-JOB-QUEUE, …) and
;;; runs each claimed job in its own child Lisp process, started with the
;;; heap size of the job's resource class. The child loads the kind's
;;; systems, calls the handler and sends progress and the result back over
;;; the channel (src/child/channel.lisp). The parent heartbeats the lease,
;;; relays progress, completes, fails or acknowledges the job, and kills the
;;; child on timeout, cancel and shutdown. A child that dies fails its job
;;; only: the supervisor keeps running.
;;;
;;; Construction (MAKE-PROCESS-SUPERVISOR QUEUE REGISTRY &key …)
;;; -------------------------------------------------------------
;;;   WORKER-ID            string, the lease holder; default a fresh
;;;                        "task-worker-process-<random hex>"
;;;   LEASE-SECONDS        positive integer, CLAIM-JOB / HEARTBEAT-JOB's
;;;                        lease, default 30
;;;   HEARTBEAT-INTERVAL   positive real < LEASE-SECONDS, seconds between
;;;                        heartbeats of a running job, default
;;;                        LEASE-SECONDS / 3
;;;   POLL-INTERVAL        positive real, seconds between two looks at a
;;;                        running child (frames, exit, cancel flag,
;;;                        timeout, heartbeat due), default 0.1
;;;   CLAIM-INTERVAL       positive real, seconds the claim loop sleeps when
;;;                        nothing is claimable, default 0.5
;;;   HEAP-SIZES           alist (RESOURCE-CLASS-NAME . MB), MB a positive
;;;                        integer: the child heap of a job of that class
;;;   DEFAULT-HEAP-MB      positive integer or NIL: the heap of a job whose
;;;                        class is NIL or not in HEAP-SIZES; NIL lets the
;;;                        child Lisp choose (no size is passed). Default NIL
;;;   CANCEL-GRACE         non-negative real, seconds a child gets to return
;;;                        after its cancel was requested before it is
;;;                        killed, default 5
;;;   LISP-COMMAND         NIL (DEFAULT-LISP-COMMAND) or a function
;;;                        (HEAP-MB BOOT-FILE) → list of strings, the
;;;                        program and its arguments. HEAP-MB is JOB-HEAP-MB
;;;                        (possibly NIL), BOOT-FILE the native namestring of
;;;                        the job's boot.lisp. Called once per launch
;;;   SOURCE-REGISTRY      :INHERIT (default): the child's ASDF source
;;;                        registry and output translations are the
;;;                        parent's (the parameters the parent's ASDF was
;;;                        initialized with: under `cl-repo test` / `cl-repo
;;;                        run`, the project registry); NIL: the child's
;;;                        ASDF configures itself; or a source-registry form
;;;                        given to ASDF:INITIALIZE-SOURCE-REGISTRY
;;;   WORK-DIRECTORY       directory pathname under which each launch gets
;;;                        its own job directory; default
;;;                        <UIOP:TEMPORARY-DIRECTORY>task-worker-process/
;;;   KEEP-WORK-DIRECTORIES  NIL (default): a job directory is deleted when
;;;                        its launch is over; T keeps it (logs, frames)
;;;   ON-CHILD-FAILURE     NIL or a function of one CHILD-FAILURE, called in
;;;                        the job's thread while the condition is being
;;;                        signalled (inside HANDLER-BIND): it may invoke one
;;;                        of the restarts below; when it returns, the
;;;                        default (CONTINUE) is taken
;;; QUEUE must be a JOB-QUEUE and REGISTRY a HANDLER-REGISTRY (CHECK-TYPE).
;;; Any other refused value signals WORKER-CONFIGURATION-ERROR (OPTION =
;;; the keyword, VALUE) with a USE-VALUE restart taking a replacement,
;;; checked again. A fresh supervisor's state is :IDLE.
;;;
;;; Heap sizes
;;; ----------
;;; (JOB-HEAP-MB SUPERVISOR JOB) = the HEAP-SIZES entry of the job's
;;; resource class, else DEFAULT-HEAP-MB. It is a plain lookup (like the
;;; registry), the only place the size is chosen. DEFAULT-LISP-COMMAND
;;; passes it to SBCL as --dynamic-space-size <MB>MB.
;;;
;;; Concurrency
;;; -----------
;;; The supervisor does not cap how many children run: the queue's resource
;;; classes do. The claim loop (START-SUPERVISOR) calls CLAIM-JOB with
;;; :KINDS (JOB-HANDLER-KINDS REGISTRY) until it returns NIL, starts one
;;; job thread per claimed job, and sleeps CLAIM-INTERVAL when nothing is
;;; claimable. So a class with LIMIT 2 runs at most two children of that
;;; class (across every supervisor on the queue), and a job with no class
;;; is not limited at all: give every heavy kind a class. A registry with
;;; no handlers claims nothing (CLAIM-JOB's :KINDS NIL would mean any kind).
;;;
;;; One launch (the job runner)
;;; ---------------------------
;;; For a claimed job J of kind K (RUN-NEXT-JOB runs it in the calling
;;; thread, the claim loop in a job thread; the behaviour is the same):
;;;  1. H = (FIND-JOB-HANDLER REGISTRY K :ERRORP NIL). No handler (the entry
;;;     was removed after the claim) → FAIL-JOB with an UNKNOWN-JOB-KIND,
;;;     no child is started.
;;;  2. A fresh job directory D under WORK-DIRECTORY; D/request.sexp and
;;;     D/boot.lisp are written (src/child/main.lisp). A payload that cannot
;;;     be written (FRAME-STRING signals) → CHILD-FAILURE :PROTOCOL-ERROR,
;;;     no child is started.
;;;  3. The child is launched with PROCESS-PROTOCOL:LAUNCH: the LISP-COMMAND
;;;     argv, directory D, stdin a pipe closed at once, stdout and stderr to
;;;     D/child.log, and :PROCESS-GROUP T when the backend supports it (so a
;;;     kill reaches the child's own children: kills use :TREE T then,
;;;     always :FORCE T). A launch that signals PROCESS-ERROR →
;;;     CHILD-FAILURE :LAUNCH-FAILED.
;;;  4. Every POLL-INTERVAL, until the child has exited:
;;;     - new frames are read from D/channel (READ-FRAMES); each :progress
;;;       frame becomes (REPORT-JOB-PROGRESS QUEUE id WORKER-ID :PHASE
;;;       :FRACTION :MESSAGE), in frame order; a :result or :error frame is
;;;       kept for the outcome. A CHANNEL-ERROR kills the child →
;;;       CHILD-FAILURE :PROTOCOL-ERROR;
;;;     - when HEARTBEAT-INTERVAL has passed since the claim or the last
;;;       heartbeat: HEARTBEAT-JOB with LEASE-SECONDS. JOB-LEASE-LOST or
;;;       JOB-STATE-ERROR there (another worker holds the job after a lease
;;;       expiry, or the job was canceled with :FORCE T) kills the child and
;;;       ends the launch with the job untouched: it is no longer ours;
;;;     - CANCEL-REQUESTED-P → the first time, D/cancel is created and the
;;;       cancel deadline set to now + CANCEL-GRACE; past the deadline the
;;;       child is killed. A canceled job is then acknowledged (below);
;;;     - past the kind's TIMEOUT (counted from the launch) the child is
;;;       killed → CHILD-FAILURE :TIMEOUT;
;;;     - STOP-SUPERVISOR's grace over → the child is killed →
;;;       CHILD-FAILURE :SHUTDOWN (or released, see Shutdown).
;;;  5. After the exit (PROCESS-PROTOCOL:WAIT reaps it), the remaining
;;;     frames are read and the outcome decided (Outcomes).
;;;  6. D is deleted unless KEEP-WORK-DIRECTORIES. No child outlives its
;;;     launch: leaving the runner by any exit (normal, error, non-local
;;;     transfer, thread kill aside) kills and reaps the child.
;;; Queue operations run in the job's thread, never inside a subscriber
;;; callback (the in-memory queue calls those with its lock held).
;;;
;;; Outcomes
;;; --------
;;; In this order:
;;;  - cancel requested (step 4): (ACKNOWLEDGE-CANCEL QUEUE id WORKER-ID);
;;;    the job ends :CANCELED with the queue's cancel reason, whatever the
;;;    child sent. (If it is :CANCELED already, nothing is done.)
;;;  - exit code 0 and a :result frame → (COMPLETE-JOB … :RESULT value).
;;;  - otherwise a CHILD-FAILURE is signalled with REASON and DETAIL:
;;;      :timeout        "timed out after <T> s"
;;;      :shutdown       "killed at supervisor shutdown"
;;;      :heap-exhausted "heap exhausted (<MB> MB)" — an :error frame with
;;;                      :HEAP-EXHAUSTED T, or a log containing "Heap
;;;                      exhausted" (SBCL's fatal message); <MB> is the
;;;                      job's heap or "default"
;;;      :handler-error  "<type>: <message>" from the :error frame
;;;      :signal         "killed by signal <N>" — exit code > 128, N = code
;;;                      - 128 (UIOP's convention)
;;;      :exit           "exited with code <N>" — any other non-zero code
;;;      :no-result      "exited with code 0 without a result"
;;;      :launch-failed  "could not start: <the PROCESS-ERROR's report>"
;;;      :protocol-error "<what could not be written or read>"
;;;    and EXIT-CODE, LOG-TAIL, JOB-ID and KIND set. The classification is
;;;    one function (a small, total mapping from exit code, frames and log
;;;    to a reason; a logic-protocol migration candidate if it grows).
;;;    Restarts around the signal (established by the runner):
;;;      CONTINUE        (default) (FAIL-JOB … :ERROR condition): the job's
;;;                      FAILURE is the report, "child failure (<reason>):
;;;                      <detail>"
;;;      RETRY-CHILD     launch a fresh child for the same claim (from step
;;;                      2; the timeout restarts). Not offered for
;;;                      :SHUTDOWN
;;;      USE-VALUE (v)   (COMPLETE-JOB … :RESULT v)
;;;    ON-CHILD-FAILURE is called first (see Construction); then CONTINUE.
;;;    The condition never reaches the debugger nor leaves the runner.
;;; Errors from the queue's own operations (task-protocol conditions other
;;; than the lease ones above) are not caught by the runner: in RUN-NEXT-JOB
;;; they reach the caller, after the child is killed; in a job thread they
;;; end that thread only (the claim loop keeps running).
;;;
;;; Shutdown
;;; --------
;;; (STOP-SUPERVISOR S &key (GRACE 30) (KILLED :FAIL) (WAIT T)): the state
;;; becomes :STOPPING and the claim loop claims nothing more. Running
;;; children get GRACE seconds to finish (their jobs complete or fail as
;;; usual, heartbeats continue); then every child of S still running is
;;; killed, those of RUN-NEXT-JOB calls included.
;;; KILLED :FAIL → its job fails with CHILD-FAILURE :SHUTDOWN (through the
;;; restarts above, minus RETRY-CHILD); KILLED :RELEASE → the job is left
;;; :RUNNING and no longer heartbeated, so the queue re-queues it when its
;;; lease expires (EXPIRE-JOB-LEASES). With WAIT T, returns once the claim
;;; loop and every job thread have ended and no child of S is live, and the
;;; state is :STOPPED; with WAIT NIL it returns at once and the state
;;; becomes :STOPPED then. An :IDLE supervisor goes to :STOPPED at once (its
;;; RUN-NEXT-JOB children, if any, still get GRACE). A second call may
;;; shorten the grace (the earlier deadline wins) and sets KILLED. → S.
;;; A stopped supervisor is not restarted (START-SUPERVISOR signals
;;; WORKER-ERROR on it).
;;;
;;; Not covered by 0.1.0: Windows and non-SBCL children (DEFAULT-LISP-COMMAND
;;; is SBCL only; another Lisp needs its own LISP-COMMAND), a pool of warm
;;; children, results larger than memory.

(defclass process-supervisor ()
  ((queue :initarg :queue :reader supervisor-queue)
   (registry :initarg :registry :reader supervisor-registry)
   (worker-id :initarg :worker-id :reader supervisor-worker-id)
   (lease-seconds :initarg :lease-seconds :reader supervisor-lease-seconds)
   (heartbeat-interval :initarg :heartbeat-interval
                       :reader supervisor-heartbeat-interval)
   (poll-interval :initarg :poll-interval :reader %supervisor-poll-interval)
   (claim-interval :initarg :claim-interval
                   :reader %supervisor-claim-interval)
   (heap-sizes :initarg :heap-sizes :reader %supervisor-heap-sizes)
   (default-heap-mb :initarg :default-heap-mb
                    :reader %supervisor-default-heap-mb)
   (cancel-grace :initarg :cancel-grace :reader %supervisor-cancel-grace)
   (lisp-command :initarg :lisp-command :reader %supervisor-lisp-command)
   (source-registry :initarg :source-registry
                    :reader %supervisor-source-registry)
   (work-directory :initarg :work-directory
                   :reader supervisor-work-directory)
   (keep-work-directories :initarg :keep-work-directories
                          :reader %supervisor-keep-work-directories)
   (on-child-failure :initarg :on-child-failure
                     :reader %supervisor-on-child-failure)
   (state :initform :idle :accessor %supervisor-state)
   (lock :initform (bt:make-recursive-lock "task-worker-process supervisor")
         :reader %supervisor-lock)
   (children :initform (make-hash-table :test 'equal)
             :reader %supervisor-children
             :documentation "Job id → process handle of its live child.")
   (threads :initform '() :accessor %supervisor-threads
            :documentation "The claim loop and the live job threads.")
   (shutdown-deadline :initform nil :accessor %supervisor-shutdown-deadline)
   (shutdown-mode :initform :fail :accessor %supervisor-shutdown-mode))
  (:documentation "Claims queue jobs and runs each in a child Lisp (see the
   file header)."))

(defun process-supervisor-p (x)
  (typep x 'process-supervisor))

;;; Small helpers

(defun %now ()
  "Seconds (a rational) on the internal real-time clock."
  (/ (get-internal-real-time) internal-time-units-per-second))

(defmacro %with-supervisor-lock ((supervisor) &body body)
  `(bt:with-recursive-lock-held ((%supervisor-lock ,supervisor))
     ,@body))

(defun %readable (form)
  "FORM printed readably under the channel's syntax (see channel.lisp)."
  (task-worker-process/child:frame-string form))

;;; Construction

(defun %positive-real-p (x)
  (and (realp x) (plusp x)))

(defun %heap-sizes-p (x)
  (and (%proper-list-p x)
       (every (lambda (entry)
                (and (consp entry) (typep (cdr entry) '(integer 1))))
              x)))

(defun %work-directory-p (x)
  (and (or (pathnamep x) (stringp x))
       (uiop:directory-pathname-p (pathname x))))

(defun %fresh-worker-id ()
  (format nil "task-worker-process-~(~x~)"
          (random (expt 2 64) (make-random-state t))))

(defun make-process-supervisor (queue registry
                                &key worker-id (lease-seconds 30)
                                  heartbeat-interval (poll-interval 0.1)
                                  (claim-interval 0.5) heap-sizes
                                  default-heap-mb (cancel-grace 5)
                                  lisp-command (source-registry :inherit)
                                  work-directory keep-work-directories
                                  on-child-failure)
  "A new :IDLE PROCESS-SUPERVISOR (see Construction in the file header)."
  (check-type queue task-protocol:job-queue)
  (check-type registry handler-registry)
  (flet ((check (option value valid-p)
           (%validated value valid-p
                       (lambda (v)
                         (error 'worker-configuration-error
                                :option option :value v)))))
    (let* ((worker-id (if worker-id
                          (check :worker-id worker-id #'stringp)
                          (%fresh-worker-id)))
           ;; the lease first: the heartbeat default and check use it
           (lease (check :lease-seconds lease-seconds
                         (lambda (x) (typep x '(integer 1)))))
           (heartbeat (check :heartbeat-interval
                             (or heartbeat-interval (/ lease 3))
                             (lambda (x) (and (%positive-real-p x) (< x lease)))))
           (poll (check :poll-interval poll-interval #'%positive-real-p))
           (claim (check :claim-interval claim-interval #'%positive-real-p))
           (heaps (check :heap-sizes heap-sizes #'%heap-sizes-p))
           (default-heap (check :default-heap-mb default-heap-mb
                                (lambda (x) (typep x '(or null (integer 1))))))
           (grace (check :cancel-grace cancel-grace
                         (lambda (x) (typep x '(real 0)))))
           (command (check :lisp-command lisp-command
                           (lambda (x) (typep x '(or null function)))))
           (registry-form (check :source-registry source-registry
                                 (lambda (x) (or (eq x :inherit) (listp x)))))
           (work (if work-directory
                     (uiop:merge-pathnames*
                      (pathname (check :work-directory work-directory
                                       #'%work-directory-p))
                      (uiop:getcwd))
                     (merge-pathnames "task-worker-process/"
                                      (uiop:temporary-directory))))
           (on-failure (check :on-child-failure on-child-failure
                              (lambda (x) (typep x '(or null function))))))
      (make-instance 'process-supervisor
                     :queue queue :registry registry :worker-id worker-id
                     :lease-seconds lease :heartbeat-interval heartbeat
                     :poll-interval poll :claim-interval claim
                     :heap-sizes heaps :default-heap-mb default-heap
                     :cancel-grace grace :lisp-command command
                     :source-registry registry-form :work-directory work
                     :keep-work-directories (and keep-work-directories t)
                     :on-child-failure on-failure))))

(defun supervisor-state (supervisor)
  ":IDLE, :RUNNING, :STOPPING or :STOPPED."
  (%with-supervisor-lock (supervisor)
    (%supervisor-state supervisor)))

(defun default-lisp-command (heap-mb boot-file)
  "The child command used when LISP-COMMAND is NIL: this image's SBCL
   runtime and core, as a list of strings
     (<runtime> \"--core\" <core> [\"--dynamic-space-size\" \"<HEAP-MB>MB\"]
      \"--noinform\" \"--disable-ldb\" \"--lose-on-corruption\"
      \"--end-runtime-options\" \"--no-sysinit\" \"--no-userinit\"
      \"--disable-debugger\" \"--load\" <BOOT-FILE>)
   with the size pair only when HEAP-MB is non-NIL. On another Lisp, or an
   SBCL whose core is embedded in its runtime, signals
   WORKER-CONFIGURATION-ERROR (OPTION :LISP-COMMAND)."
  (check-type heap-mb (or null (integer 1)))
  #+sbcl
  (let ((runtime sb-ext:*runtime-pathname*)
        (core sb-ext:*core-pathname*))
    (when (or (null runtime) (null core)
              (let ((r (probe-file runtime)) (c (probe-file core)))
                (and r c (equal r c))))
      (error 'worker-configuration-error
             :option :lisp-command :value nil
             :message "this SBCL's core is embedded in its runtime: give a :lisp-command"))
    (append (list (uiop:native-namestring runtime)
                  "--core" (uiop:native-namestring core))
            (when heap-mb
              (list "--dynamic-space-size" (format nil "~dMB" heap-mb)))
            (list "--noinform" "--disable-ldb" "--lose-on-corruption"
                  "--end-runtime-options" "--no-sysinit" "--no-userinit"
                  "--disable-debugger" "--load"
                  (if (stringp boot-file) boot-file (uiop:native-namestring boot-file)))))
  #-sbcl
  (progn
    heap-mb boot-file
    (error 'worker-configuration-error
           :option :lisp-command :value nil
           :message "the default child command is SBCL only: give a :lisp-command")))

(defun job-heap-mb (supervisor job)
  "The heap size in MB for JOB (a task-protocol JOB) or NIL (see Heap
   sizes in the file header)."
  (let ((class (task-protocol:job-resource-class job)))
    (or (and class (cdr (assoc class (%supervisor-heap-sizes supervisor))))
        (%supervisor-default-heap-mb supervisor))))

;;; Live children

(defun supervisor-running-jobs (supervisor)
  "Ids of the jobs whose child is live now (launched, not yet reaped), in
   no particular order, from both the claim loop and RUN-NEXT-JOB."
  (%with-supervisor-lock (supervisor)
    (loop for id being the hash-keys of (%supervisor-children supervisor)
          collect id)))

(defun supervisor-child-pid (supervisor job-id)
  "The OS pid of JOB-ID's live child, or NIL (no live child, or the
   backend cannot tell)."
  (let ((handle (%with-supervisor-lock (supervisor)
                  (gethash job-id (%supervisor-children supervisor)))))
    (and handle (process-protocol:pid handle))))

;;; Shutdown state, as the runners see it

(defun %shutdown-due-p (supervisor &optional (now (%now)))
  (let ((deadline (%with-supervisor-lock (supervisor)
                    (%supervisor-shutdown-deadline supervisor))))
    (and deadline (>= now deadline))))

(defun %shutdown-mode (supervisor)
  (%with-supervisor-lock (supervisor)
    (%supervisor-shutdown-mode supervisor)))

;;; One launch

(defstruct (%launch (:conc-name %l-))
  job handler heap-mb
  (dir nil)                  ; the job directory D
  (handle nil)               ; the process handle, once launched
  (group-p nil)              ; launched with :PROCESS-GROUP T
  (offset 0)                 ; channel bytes consumed
  (final nil)                ; the :result / :error frame
  (launched-at nil)
  (cancel-deadline nil)      ; set on the first cancel tick
  (killed nil)               ; why the parent killed the child, first cause
                             ; wins (:lost overrides): :cancel :timeout
                             ; :shutdown :protocol :lost
  (detail nil)               ; the :protocol detail
  (exit-code nil)            ; once reaped
  (log-tail nil))

(defun %file (launch name)
  (merge-pathnames name (%l-dir launch)))

(defun %kill-child (launch)
  "Kill LAUNCH's child unless it is reaped: forced, its tree when launched
   in its own group."
  (let ((handle (%l-handle launch)))
    (when (and handle (null (%l-exit-code launch)))
      (process-protocol:kill handle :force t :tree (%l-group-p launch)))))

(defun %kill (launch why &optional detail)
  "Kill the child for WHY (see the KILLED slot)."
  (when (or (null (%l-killed launch)) (eq why :lost))
    (setf (%l-killed launch) why)
    (when detail (setf (%l-detail launch) detail)))
  (%kill-child launch))

(defun %log-tail (directory)
  "The last (at most 4096) characters of DIRECTORY's child.log, decoded
   leniently, or NIL."
  (when directory
    (handler-case
        (with-open-file (in (merge-pathnames task-worker-process/child:+log-file+ directory)
                            :element-type '(unsigned-byte 8) :if-does-not-exist nil)
          (when in
            (let* ((length (file-length in))
                   (start (max 0 (- length 16384)))
                   (octets (make-array (- length start) :element-type '(unsigned-byte 8))))
              (file-position in start)
              (let* ((n (read-sequence octets in))
                     (text (babel:octets-to-string octets :end n :encoding :utf-8
                                                          :errorp nil)))
                (subseq text (max 0 (- (length text) 4096)))))))
      (file-error () nil))))

(defun %failure-outcome (launch reason detail)
  "→ (:FAILURE child-failure), the condition made, not signalled."
  (let ((job (%l-job launch)))
    (list :failure
          (make-condition 'child-failure
                          :reason reason :detail detail
                          :exit-code (%l-exit-code launch)
                          :log-tail (or (%l-log-tail launch) (%log-tail (%l-dir launch)))
                          :job-id (task-protocol:job-id job)
                          :kind (task-protocol:job-kind job)))))

(defun %classify (supervisor launch)
  "The outcome of a reaped child: the one total mapping of the file
   header's Outcomes (kill cause, exit code, frames, log → outcome).
   → (:LOST) | (:RELEASED) | (:CANCEL) | (:COMPLETE value)
     | (:FAILURE child-failure)."
  (setf (%l-log-tail launch) (%log-tail (%l-dir launch)))
  (let ((code (%l-exit-code launch))
        (frame (%l-final launch))
        (why (%l-killed launch))
        (log (or (%l-log-tail launch) "")))
    (flet ((fail (reason detail) (%failure-outcome launch reason detail)))
      (cond
        ((eq why :lost) '(:lost))
        ((and (eq why :shutdown) (eq (%shutdown-mode supervisor) :release)) '(:released))
        ((%l-cancel-deadline launch) '(:cancel))
        ((and (eql code 0) (eq (first frame) :result)) (list :complete (second frame)))
        ((eq why :protocol) (fail :protocol-error (%l-detail launch)))
        ((eq why :timeout)
         (fail :timeout (format nil "timed out after ~a s"
                                (job-handler-timeout (%l-handler launch)))))
        ((eq why :shutdown) (fail :shutdown "killed at supervisor shutdown"))
        ((or (and (eq (first frame) :error) (getf (rest frame) :heap-exhausted))
             (search "Heap exhausted" log))
         (fail :heap-exhausted (format nil "heap exhausted (~a MB)"
                                       (or (%l-heap-mb launch) "default"))))
        ((eq (first frame) :error)
         (fail :handler-error (format nil "~a: ~a" (getf (rest frame) :type)
                                      (getf (rest frame) :message))))
        ((and code (> code 128))
         (fail :signal (format nil "killed by signal ~d" (- code 128))))
        ((and code (/= code 0))
         (fail :exit (format nil "exited with code ~d" code)))
        (t (fail :no-result "exited with code 0 without a result"))))))

(defun %relay-progress (supervisor launch frame)
  (destructuring-bind (&key phase fraction message &allow-other-keys) (rest frame)
    (handler-case
        (task-protocol:report-job-progress (supervisor-queue supervisor)
                                           (task-protocol:job-id (%l-job launch))
                                           (supervisor-worker-id supervisor)
                                           :phase phase :fraction fraction
                                           :message message)
      ;; the job is no longer ours (JOB-LEASE-LOST is a subclass)
      (task-protocol:job-state-error ()
        (%kill launch :lost)))))

(defun %drain-frames (supervisor launch)
  "Read the new frames: relay progress, keep the final frame. A bad frame
   kills the child (:PROTOCOL)."
  (unless (member (%l-killed launch) '(:protocol :lost))
    (multiple-value-bind (frames offset)
        (handler-case (task-worker-process/child:read-frames
                       (%file launch task-worker-process/child:+channel-file+)
                       (%l-offset launch))
          (task-worker-process/child:channel-error (e)
            (%kill launch :protocol (format nil "cannot read the channel: ~a" e))
            (return-from %drain-frames)))
      (setf (%l-offset launch) offset)
      (dolist (frame frames)
        (case (and (consp frame) (first frame))
          (:progress
           (unless (eq (%l-killed launch) :lost)
             (%relay-progress supervisor launch frame)))
          ((:result :error) (setf (%l-final launch) frame))
          (t
           (%kill launch :protocol "cannot read the channel: an unknown frame")
           (return-from %drain-frames)))))))

(defun %poll (supervisor launch heartbeat)
  "Watch the running child until it is reaped (One launch, steps 4–5).
   HEARTBEAT is a cons whose CAR is the time of the claim or of the last
   heartbeat. → the outcome (%CLASSIFY)."
  (let* ((queue (supervisor-queue supervisor))
         (id (task-protocol:job-id (%l-job launch)))
         (worker (supervisor-worker-id supervisor))
         (handle (%l-handle launch))
         (timeout (job-handler-timeout (%l-handler launch))))
    (loop
      (let ((code (process-protocol:exit-code handle)))
        ;; frames after the exit check: whatever the child wrote before it
        ;; exited is on disk once the exit is seen
        (%drain-frames supervisor launch)
        (when (or code (%l-killed launch))
          (setf (%l-exit-code launch) (or code (process-protocol:wait handle)))
          (unless code (%drain-frames supervisor launch))
          (return (%classify supervisor launch))))
      (let ((now (%now)))
        (when (>= (- now (car heartbeat)) (supervisor-heartbeat-interval supervisor))
          (handler-case
              (progn
                (task-protocol:heartbeat-job queue id worker
                                             :lease-seconds (supervisor-lease-seconds supervisor))
                (setf (car heartbeat) now))
            ;; another worker holds it, or it was canceled with :FORCE T
            (task-protocol:job-state-error ()
              (%kill launch :lost))))
        (unless (%l-killed launch)
          (when (and (null (%l-cancel-deadline launch))
                     (task-protocol:cancel-requested-p queue id))
            (with-open-file (out (%file launch task-worker-process/child:+cancel-file+)
                                 :direction :output :if-exists :supersede
                                 :if-does-not-exist :create)
              (declare (ignorable out)))
            (setf (%l-cancel-deadline launch)
                  (+ now (%supervisor-cancel-grace supervisor))))
          (cond ((and (%l-cancel-deadline launch) (>= now (%l-cancel-deadline launch)))
                 (%kill launch :cancel))
                ((and timeout (>= (- now (%l-launched-at launch)) timeout))
                 (%kill launch :timeout))
                ((%shutdown-due-p supervisor now)
                 (%kill launch :shutdown)))))
      (unless (%l-killed launch)
        (sleep (%supervisor-poll-interval supervisor))))))

(defun %fresh-job-directory (supervisor)
  (let ((root (supervisor-work-directory supervisor))
        (state (make-random-state t)))
    (ensure-directories-exist root)
    (loop
      (let ((dir (merge-pathnames (format nil "job-~(~36r~)/" (random (expt 36 12) state))
                                  root)))
        (when (nth-value 1 (ensure-directories-exist dir))
          (return dir))))))

(defun %asdf-parameter (name)
  "The value of ASDF's internal special NAME, or NIL."
  (let ((symbol (find-symbol name '#:asdf)))
    (and symbol (boundp symbol) (symbol-value symbol))))

(defun %boot-text (supervisor directory)
  "The text of DIRECTORY's boot.lisp (see src/child/main.lisp). Every
   datum is printed readably (PRINT-NOT-READABLE otherwise); the code is
   read form by form by LOAD, after ASDF is loaded."
  (let ((registry (%supervisor-source-registry supervisor))
        (asd (asdf:system-source-file (asdf:find-system "task-worker-process/child"))))
    (with-output-to-string (out)
      (format out ";;; task-worker-process child boot file~%(require \"asdf\")~%")
      (case registry
        (:inherit
         ;; NIL parameters: the parent's ASDF configured itself from the
         ;; environment and defaults, which the child inherits anyway
         (let ((sources (%asdf-parameter "*SOURCE-REGISTRY-PARAMETER*"))
               (outputs (%asdf-parameter "*OUTPUT-TRANSLATIONS-PARAMETER*"))
               (central (remove-if-not (lambda (e) (or (pathnamep e) (stringp e)))
                                       asdf:*central-registry*)))
           (when sources
             (format out "(asdf:initialize-source-registry '~a)~%" (%readable sources)))
           (when outputs
             (format out "(asdf:initialize-output-translations '~a)~%" (%readable outputs)))
           (when central
             (format out "(setf asdf:*central-registry* (append '~a asdf:*central-registry*))~%"
                     (%readable central)))))
        ((nil))
        (t (format out "(asdf:initialize-source-registry '~a)~%" (%readable registry))))
      (when asd
        (format out "(asdf:load-asd ~a)~%" (%readable asd)))
      (format out "(asdf:load-system \"task-worker-process/child\")~%")
      (format out "(uiop:symbol-call \"TASK-WORKER-PROCESS/CHILD\" \"CHILD-MAIN\" ~a)~%"
              (%readable directory)))))

(defun %write-text-file (pathname text)
  (with-open-file (out pathname :direction :output :external-format :utf-8
                                :if-exists :supersede :if-does-not-exist :create)
    (write-string text out)))

(defun %register-child (supervisor launch)
  (%with-supervisor-lock (supervisor)
    (setf (gethash (task-protocol:job-id (%l-job launch)) (%supervisor-children supervisor))
          (%l-handle launch))))

(defun %end-launch (supervisor launch)
  "Every exit from a launch: kill and reap the child if needed, forget it,
   delete D unless kept."
  (let ((handle (%l-handle launch)))
    (when handle
      (unwind-protect
           (unless (%l-exit-code launch)
             (%kill-child launch)
             (setf (%l-exit-code launch) (process-protocol:wait handle)))
        (%with-supervisor-lock (supervisor)
          (remhash (task-protocol:job-id (%l-job launch))
                   (%supervisor-children supervisor))))))
  (let ((dir (%l-dir launch))
        (root (supervisor-work-directory supervisor)))
    (when (and dir (not (%supervisor-keep-work-directories supervisor)))
      (handler-case
          (uiop:delete-directory-tree dir :validate (lambda (p) (uiop:subpathp p root))
                                          :if-does-not-exist :ignore)
        (file-error () nil)))))

(defun %launch-once (supervisor job handler heartbeat)
  "One child for JOB (One launch, steps 2–6). → the outcome (see
   %CLASSIFY); the child is reaped and D gone when it returns."
  (let ((launch (make-%launch :job job :handler handler
                              :heap-mb (job-heap-mb supervisor job))))
    (unwind-protect
         (block launch
           (flet ((fail (reason detail)
                    (return-from launch (%failure-outcome launch reason detail))))
             (when (%shutdown-due-p supervisor)
               (return-from launch
                 (if (eq (%shutdown-mode supervisor) :release)
                     '(:released)
                     (fail :shutdown "killed at supervisor shutdown"))))
             (setf (%l-dir launch) (%fresh-job-directory supervisor))
             ;; both texts before any file or LISP-COMMAND
             (let ((request (handler-case
                                (%readable
                                 (list :job-id (task-protocol:job-id job)
                                       :kind (task-protocol:job-kind job)
                                       :payload (task-protocol:job-payload job)
                                       :handler (job-handler-function handler)
                                       :systems (job-handler-systems handler)))
                              (print-not-readable (e)
                                (fail :protocol-error
                                      (format nil "cannot write the request: ~a" e)))))
                   (boot (handler-case (%boot-text supervisor (%l-dir launch))
                           (print-not-readable (e)
                             (fail :protocol-error
                                   (format nil "cannot write the boot file: ~a" e))))))
               (%write-text-file (%file launch task-worker-process/child:+request-file+)
                                 request)
               (%write-text-file (%file launch task-worker-process/child:+boot-file+)
                                 boot))
             (let* ((boot-file (uiop:native-namestring
                                (%file launch task-worker-process/child:+boot-file+)))
                    (argv (funcall (or (%supervisor-lisp-command supervisor)
                                       #'default-lisp-command)
                                   (%l-heap-mb launch) boot-file))
                    (group (and (process-protocol:supports-p :process-group) t)))
               (setf (%l-group-p launch) group
                     (%l-launched-at launch) (%now))
               (handler-case
                   (setf (%l-handle launch)
                         (process-protocol:launch
                          argv :directory (%l-dir launch)
                               :input nil ; a pipe, closed below
                               :output (%file launch task-worker-process/child:+log-file+)
                               :error-output :output
                               :process-group group))
                 (process-protocol:process-error (e)
                   (fail :launch-failed (format nil "could not start: ~a" e))))
               (%register-child supervisor launch)
               (let ((stdin (process-protocol:stdin (%l-handle launch))))
                 (when stdin
                   (handler-case (close stdin)
                     (stream-error () nil))))
               (%poll supervisor launch heartbeat))))
      (%end-launch supervisor launch))))

;;; The runner: one claimed job, its restarts

(defun %finish-job (thunk)
  "Run a terminal queue operation; JOB-STATE-ERROR (the job is no longer
   ours: forced cancel, lease lost) → nothing."
  (handler-case (funcall thunk)
    (task-protocol:job-state-error () nil)))

(defun %acknowledge-cancel (supervisor id)
  (let ((queue (supervisor-queue supervisor)))
    (unless (eq :canceled (task-protocol:job-state (task-protocol:job-status queue id)))
      (%finish-job (lambda ()
                     (task-protocol:acknowledge-cancel queue id
                                                       (supervisor-worker-id supervisor)))))))

(defun %handle-child-failure (supervisor condition)
  "Signal CONDITION (a CHILD-FAILURE) with the runner's restarts, calling
   ON-CHILD-FAILURE first, then taking CONTINUE. → T for RETRY-CHILD, else
   NIL once the job was failed or completed."
  (let ((queue (supervisor-queue supervisor))
        (id (child-failure-job-id condition))
        (worker (supervisor-worker-id supervisor))
        (function (%supervisor-on-child-failure supervisor))
        (retryable (not (eq :shutdown (child-failure-reason condition)))))
    (restart-case
        (handler-bind ((child-failure
                         (lambda (c)
                           (when (eq c condition)
                             (when function (funcall function c))
                             ;; the default: the signal never declines out
                             ;; of the runner
                             (invoke-restart 'continue)))))
          (signal condition))
      (continue ()
        :report "Fail the job with this child failure."
        (%finish-job (lambda () (task-protocol:fail-job queue id worker :error condition)))
        nil)
      (retry-child ()
        :report "Launch a fresh child for the same claim."
        :test (lambda (c) (declare (ignore c)) retryable)
        t)
      (use-value (value)
        :report "Complete the job with a value instead."
        :interactive %read-new-value
        (%finish-job (lambda () (task-protocol:complete-job queue id worker :result value)))
        nil))))

(defun %run-claimed-job (supervisor job)
  "Run claimed JOB to its end in this thread (see One launch)."
  (let* ((queue (supervisor-queue supervisor))
         (id (task-protocol:job-id job))
         (worker (supervisor-worker-id supervisor))
         (heartbeat (list (%now)))  ; the claim's lease clock, across retries
         (handler (find-job-handler (supervisor-registry supervisor)
                                    (task-protocol:job-kind job) :errorp nil)))
    (if (null handler)
        (%finish-job (lambda ()
                       (task-protocol:fail-job
                        queue id worker
                        :error (make-condition 'unknown-job-kind
                                               :kind (task-protocol:job-kind job)))))
        (loop
          (let ((outcome (%launch-once supervisor job handler heartbeat)))
            (ecase (first outcome)
              (:complete
               (%finish-job (lambda ()
                              (task-protocol:complete-job queue id worker
                                                          :result (second outcome))))
               (return))
              (:cancel (%acknowledge-cancel supervisor id) (return))
              ((:lost :released) (return))
              (:failure
               (unless (%handle-child-failure supervisor (second outcome))
                 (return)))))))))

(defun %claim (supervisor)
  "CLAIM-JOB for the registry's kinds, or NIL (also for an empty
   registry: :KINDS NIL would mean any kind)."
  (let ((kinds (job-handler-kinds (supervisor-registry supervisor))))
    (and kinds
         (task-protocol:claim-job (supervisor-queue supervisor)
                                  (supervisor-worker-id supervisor)
                                  :kinds kinds
                                  :lease-seconds (supervisor-lease-seconds supervisor)))))

(defun run-next-job (supervisor)
  "Claim the next admissible job of a registered kind (CLAIM-JOB with
   :KINDS (JOB-HANDLER-KINDS registry), WORKER-ID and LEASE-SECONDS) and run
   it to its end in this thread (see One launch). → the job's snapshot
   (JOB-STATUS) once the launch is over, or NIL when nothing was claimed
   (also when the registry is empty).
   Works whatever the supervisor's state, the claim loop's included."
  (check-type supervisor process-supervisor)
  (let ((job (%claim supervisor)))
    (when job
      (%run-claimed-job supervisor job)
      (task-protocol:job-status (supervisor-queue supervisor) (task-protocol:job-id job)))))

;;; Claim loop and shutdown

(defun %forget-thread (supervisor thread)
  (%with-supervisor-lock (supervisor)
    (setf (%supervisor-threads supervisor)
          (remove thread (%supervisor-threads supervisor)))))

(defun %sleep-while-running (supervisor seconds)
  "Sleep SECONDS in small steps, returning early once the state is no
   longer :RUNNING."
  (let ((deadline (+ (%now) seconds)))
    (loop for left = (- deadline (%now))
          while (and (plusp left) (eq :running (supervisor-state supervisor)))
          do (sleep (min left 1/20)))))

(defun %start-job-thread (supervisor job)
  (%with-supervisor-lock (supervisor)
    ;; registered under the lock before the thread can forget itself
    (push (bt:make-thread
           (lambda ()
             (unwind-protect
                  ;; a queue error (or a configuration error) ends this
                  ;; job's thread only; the child is already killed
                  (handler-case (%run-claimed-job supervisor job)
                    (task-protocol:task-error () nil)
                    (worker-error () nil))
               (%forget-thread supervisor (bt:current-thread))))
           :name "task-worker-process job")
          (%supervisor-threads supervisor))))

(defun %claim-loop (supervisor)
  (unwind-protect
       (loop while (eq :running (supervisor-state supervisor))
             do (let ((job (handler-case (%claim supervisor)
                             ;; a transient queue error: try again later
                             (task-protocol:task-error () nil))))
                  (if job
                      (%start-job-thread supervisor job)
                      (%sleep-while-running supervisor
                                            (%supervisor-claim-interval supervisor)))))
    (%forget-thread supervisor (bt:current-thread))))

(defun start-supervisor (supervisor)
  "Start the claim loop in its own thread (see Concurrency); the state
   becomes :RUNNING. On a :RUNNING supervisor, does nothing. On a
   :STOPPING or :STOPPED one, signals WORKER-ERROR. → SUPERVISOR."
  (check-type supervisor process-supervisor)
  (let ((refused nil))
    (%with-supervisor-lock (supervisor)
      (case (%supervisor-state supervisor)
        (:idle
         (setf (%supervisor-state supervisor) :running)
         (push (bt:make-thread (lambda () (%claim-loop supervisor))
                               :name "task-worker-process claim loop")
               (%supervisor-threads supervisor)))
        (:running)
        (t (setf refused (%supervisor-state supervisor)))))
    (when refused
      (error 'worker-error
             :message (format nil "task-worker-process: the supervisor is ~(~a~) and cannot be started again"
                              refused)))
    supervisor))

(defun %await-stop (supervisor)
  "Wait for the claim loop, the job threads and every live child of
   SUPERVISOR, then mark it :STOPPED."
  (loop
    (let ((threads (%with-supervisor-lock (supervisor)
                     (remove (bt:current-thread) (%supervisor-threads supervisor)))))
      (if threads
          (mapc #'bt:join-thread threads)
          (return))))
  ;; RUN-NEXT-JOB children: their runners see the deadline too
  (loop until (zerop (%with-supervisor-lock (supervisor)
                       (hash-table-count (%supervisor-children supervisor))))
        do (sleep 1/20))
  (%with-supervisor-lock (supervisor)
    (when (eq :stopping (%supervisor-state supervisor))
      (setf (%supervisor-state supervisor) :stopped))))

(defun stop-supervisor (supervisor &key (grace 30) (killed :fail) (wait t))
  "See Shutdown in the file header. GRACE is a non-negative real; KILLED
   :FAIL or :RELEASE (CHECK-TYPE). → SUPERVISOR."
  (check-type supervisor process-supervisor)
  (check-type grace (real 0))
  (check-type killed (member :fail :release))
  (%with-supervisor-lock (supervisor)
    (let ((deadline (+ (%now) grace))
          (old (%supervisor-shutdown-deadline supervisor)))
      (setf (%supervisor-shutdown-deadline supervisor) (if old (min old deadline) deadline)
            (%supervisor-shutdown-mode supervisor) killed))
    (case (%supervisor-state supervisor)
      (:idle (setf (%supervisor-state supervisor) :stopped))
      (:running (setf (%supervisor-state supervisor) :stopping))))
  (if wait
      (%await-stop supervisor)
      (bt:make-thread (lambda () (%await-stop supervisor))
                      :name "task-worker-process stop"))
  supervisor)
