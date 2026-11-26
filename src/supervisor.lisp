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

(defun make-process-supervisor (queue registry
                                &key worker-id (lease-seconds 30)
                                  heartbeat-interval (poll-interval 0.1)
                                  (claim-interval 0.5) heap-sizes
                                  default-heap-mb (cancel-grace 5)
                                  lisp-command (source-registry :inherit)
                                  work-directory keep-work-directories
                                  on-child-failure)
  "A new :IDLE PROCESS-SUPERVISOR (see Construction in the file header)."
  (declare (ignore queue registry worker-id lease-seconds heartbeat-interval
                   poll-interval claim-interval heap-sizes default-heap-mb
                   cancel-grace lisp-command source-registry work-directory
                   keep-work-directories on-child-failure))
  (%pending 'make-process-supervisor))

(defun supervisor-state (supervisor)
  ":IDLE, :RUNNING, :STOPPING or :STOPPED."
  (%supervisor-state supervisor))

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
  (declare (ignore heap-mb boot-file))
  (%pending 'default-lisp-command))

(defun job-heap-mb (supervisor job)
  "The heap size in MB for JOB (a task-protocol JOB) or NIL (see Heap
   sizes in the file header)."
  (declare (ignore supervisor job))
  (%pending 'job-heap-mb))

(defun run-next-job (supervisor)
  "Claim the next admissible job of a registered kind (CLAIM-JOB with
   :KINDS (JOB-HANDLER-KINDS registry), WORKER-ID and LEASE-SECONDS) and run
   it to its end in this thread (see One launch). → the job's snapshot
   (JOB-STATUS) once the launch is over, or NIL when nothing was claimed
   (also when the registry is empty).
   Works whatever the supervisor's state, the claim loop's included."
  (declare (ignore supervisor))
  (%pending 'run-next-job))

(defun start-supervisor (supervisor)
  "Start the claim loop in its own thread (see Concurrency); the state
   becomes :RUNNING. On a :RUNNING supervisor, does nothing. On a
   :STOPPING or :STOPPED one, signals WORKER-ERROR. → SUPERVISOR."
  (declare (ignore supervisor))
  (%pending 'start-supervisor))

(defun stop-supervisor (supervisor &key (grace 30) (killed :fail) (wait t))
  "See Shutdown in the file header. GRACE is a non-negative real; KILLED
   :FAIL or :RELEASE (CHECK-TYPE). → SUPERVISOR."
  (declare (ignore supervisor grace killed wait))
  (%pending 'stop-supervisor))

(defun supervisor-running-jobs (supervisor)
  "Ids of the jobs whose child is live now (launched, not yet reaped), in
   no particular order, from both the claim loop and RUN-NEXT-JOB."
  (declare (ignore supervisor))
  (%pending 'supervisor-running-jobs))

(defun supervisor-child-pid (supervisor job-id)
  "The OS pid of JOB-ID's live child, or NIL (no live child, or the
   backend cannot tell)."
  (declare (ignore supervisor job-id))
  (%pending 'supervisor-child-pid))
