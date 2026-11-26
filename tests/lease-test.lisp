(in-package #:task-worker-process/tests)

;;; 0.1.0 contract: heartbeats keep a job longer than its lease claimed.

(deftest heartbeats-keep-a-long-job-claimed
  (let* ((queue (%queue))
         (s (%supervisor queue :lease-seconds 2 :heartbeat-interval 0.4))
         (id (%submit queue :slow :payload '(:seconds 6) :resource-class :tiny))
         (stop nil)
         (stolen '())
         (competitor (%spawn (lambda ()
                               ;; another worker: CLAIM-JOB expires leases
                               ;; first, so it would take the job as soon as
                               ;; its lease ran out
                               (loop until stop
                                     do (let ((j (q:claim-job queue "competitor")))
                                          (when j (push (q:job-id j) stolen)))
                                        (sleep 0.2))))))
    (let ((job (unwind-protect (w:run-next-job s)
                 (setf stop t)
                 (funcall competitor))))
      (ok (eq :completed (q:job-state job))))
    (ok (null stolen) "the competitor never got the job")
    (ok (equal '(:slept (:seconds 6)) (q:job-result (q:job-status queue id))))
    (ok (= 1 (q:job-attempts (q:job-status queue id))))
    (ok (notany (lambda (e) (and (q:job-transition-p e)
                                 (eq :lease-expired (q:job-transition-reason e))))
                (q:job-events queue id)))))
