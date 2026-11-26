(defpackage #:task-worker-process
  (:use #:cl)
  (:nicknames #:stack-task-worker)
  (:export #:worker-error
           #:worker-error-message
           #:worker-configuration-error
           #:worker-configuration-error-option
           #:worker-configuration-error-value
           #:invalid-job-handler
           #:invalid-job-handler-kind
           #:unknown-job-kind
           #:unknown-job-kind-kind
           #:child-failure
           #:child-failure-job-id
           #:child-failure-kind
           #:child-failure-reason
           #:child-failure-exit-code
           #:child-failure-detail
           #:child-failure-log-tail
           #:child-failure-reason-type
           #:retry-child

           ;; registry
           #:handler-registry
           #:handler-registry-p
           #:make-handler-registry
           #:job-handler
           #:job-handler-p
           #:job-handler-kind
           #:job-handler-function
           #:job-handler-systems
           #:job-handler-timeout
           #:define-job-handler
           #:find-job-handler
           #:remove-job-handler
           #:list-job-handlers
           #:job-handler-kinds

           ;; supervisor
           #:process-supervisor
           #:process-supervisor-p
           #:make-process-supervisor
           #:supervisor-queue
           #:supervisor-registry
           #:supervisor-worker-id
           #:supervisor-state
           #:supervisor-lease-seconds
           #:supervisor-heartbeat-interval
           #:supervisor-work-directory
           #:default-lisp-command
           #:job-heap-mb
           #:run-next-job
           #:start-supervisor
           #:stop-supervisor
           #:supervisor-running-jobs
           #:supervisor-child-pid))

(in-package #:task-worker-process)

(defun %pending (name)
  "The stub of every 0.1.0 operation not implemented yet."
  (error 'worker-error
         :message (format nil "task-worker-process 0.1.0: ~(~a~) is not implemented yet"
                          name)))
