(in-package #:task-worker-process)

;;; 0.1.0 conditions (given). CLHS 9: typed conditions with slots and
;;; reports; restarts are established where the recovery is possible (see
;;; registry.lisp and supervisor.lisp).
;;;
;;;   worker-error                       root (an ERROR)
;;;     worker-configuration-error       a bad option value (USE-VALUE)
;;;       invalid-job-handler            a bad DEFINE-JOB-HANDLER argument
;;;     unknown-job-kind                 FIND-JOB-HANDLER (USE-VALUE)
;;;     child-failure                    a child did not deliver a result
;;;                                      (CONTINUE, RETRY-CHILD, USE-VALUE)
;;;
;;; Queue conditions (task-protocol's JOB-ERROR tree) are task-protocol's:
;;; the supervisor handles them by their own types and never wraps them.

(define-condition worker-error (error)
  ((message :initarg :message :initform nil :reader worker-error-message))
  (:report (lambda (c s)
             (format s "~a" (or (worker-error-message c)
                                "task-worker-process error")))))

(define-condition worker-configuration-error (worker-error)
  ((option :initarg :option :initform nil
           :reader worker-configuration-error-option
           :documentation "The keyword argument that was refused.")
   (value :initarg :value :initform nil
          :reader worker-configuration-error-value))
  (:report (lambda (c s)
             (format s "task-worker-process: bad ~(~s~) ~s~@[: ~a~]"
                     (worker-configuration-error-option c)
                     (worker-configuration-error-value c)
                     (worker-error-message c)))))

(define-condition invalid-job-handler (worker-configuration-error)
  ((kind :initarg :kind :initform nil :reader invalid-job-handler-kind))
  (:report (lambda (c s)
             (format s "task-worker-process: job kind ~s: bad ~(~s~) ~s~@[: ~a~]"
                     (invalid-job-handler-kind c)
                     (worker-configuration-error-option c)
                     (worker-configuration-error-value c)
                     (worker-error-message c)))))

(define-condition unknown-job-kind (worker-error)
  ((kind :initarg :kind :initform nil :reader unknown-job-kind-kind))
  (:report (lambda (c s)
             (format s "task-worker-process: no handler for job kind ~s"
                     (unknown-job-kind-kind c)))))

(deftype child-failure-reason-type ()
  "Why a child did not deliver a result (see supervisor.lisp, Outcomes)."
  '(member :exit :signal :heap-exhausted :handler-error :no-result
           :timeout :launch-failed :protocol-error :shutdown))

(define-condition child-failure (worker-error)
  ((job-id :initarg :job-id :initform nil :reader child-failure-job-id)
   (kind :initarg :kind :initform nil :reader child-failure-kind)
   (reason :initarg :reason :reader child-failure-reason
           :documentation "A CHILD-FAILURE-REASON-TYPE keyword.")
   (exit-code :initarg :exit-code :initform nil
              :reader child-failure-exit-code
              :documentation "As PROCESS-PROTOCOL:WAIT returned it (UIOP:
               128 + the signal number for a signalled child), or NIL when
               the child was never started.")
   (detail :initarg :detail :initform nil :reader child-failure-detail
           :documentation "One line saying what happened (see Outcomes).")
   (log-tail :initarg :log-tail :initform nil :reader child-failure-log-tail
             :documentation "The last (at most 4096) characters of the
              child's log, or NIL."))
  (:report (lambda (c s)
             (format s "child failure (~(~a~)): ~a"
                     (child-failure-reason c)
                     (or (child-failure-detail c) "no detail")))))
