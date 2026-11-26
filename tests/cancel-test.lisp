(in-package #:task-worker-process/tests)

;;; 0.1.0 contract: cancel. The flag is polled; the child gets CANCEL-GRACE
;;; seconds (1 in these tests unless given), then it is killed; the job is
;;; acknowledged.

(deftest cancel-kills-a-child-that-ignores-it
  (let* ((queue (%queue))
         (s (%supervisor queue))
         (id (%submit queue :sleep :resource-class :tiny))
         (wait (%spawn (lambda () (w:run-next-job s))))
         (pid (%wait-for-pid queue id)))
    (ok pid)
    (ok (and pid (eql pid (w:supervisor-child-pid s id))) "SUPERVISOR-CHILD-PID")
    (ok (equal (list id) (w:supervisor-running-jobs s)))
    (q:cancel-job queue id :reason "not needed")
    (multiple-value-bind (job err done) (funcall wait)
      (ok done)
      (ok (null err))
      (ok (and job (eq :canceled (q:job-state job)))))
    (ok (eq :canceled (%state queue id)))
    (ok (equal "not needed" (%failure queue id)) "the queue's cancel reason")
    (ok (and pid (%gone-p pid)) "the process is gone")
    (ok (null (w:supervisor-child-pid s id)))
    (ok (null (w:supervisor-running-jobs s)))))

(deftest cooperative-cancel
  (let* ((queue (%queue))
         (s (%supervisor queue :cancel-grace 60))
         (id (%submit queue :cooperative :resource-class :tiny))
         (wait (%spawn (lambda () (w:run-next-job s))))
         (pid (%wait-for-pid queue id)))
    (ok pid)
    (let ((asked (get-internal-real-time)))
      (q:cancel-job queue id)
      (multiple-value-bind (job err done) (funcall wait)
        (declare (ignore job))
        (ok done)
        (ok (null err)))
      (ok (< (/ (- (get-internal-real-time) asked) internal-time-units-per-second) 20)
          "the handler saw CANCEL-REQUESTED-P and returned well before the grace"))
    (ok (eq :canceled (%state queue id)))
    (ok (and pid (%gone-p pid)))))

(deftest forced-cancel-abandons-the-job
  (let* ((queue (%queue))
         (s (%supervisor queue :lease-seconds 3 :heartbeat-interval 0.3))
         (id (%submit queue :sleep :resource-class :tiny))
         (wait (%spawn (lambda () (w:run-next-job s))))
         (pid (%wait-for-pid queue id)))
    (ok pid)
    ;; a backend that killed the job elsewhere: the runner's next heartbeat
    ;; signals JOB-STATE-ERROR, it kills the child and leaves the job alone
    (q:cancel-job queue id :force t :reason "forced")
    (multiple-value-bind (job err done) (funcall wait)
      (declare (ignore job))
      (ok done)
      (ok (null err)))
    (ok (eq :canceled (%state queue id)))
    (ok (equal "forced" (%failure queue id)))
    (ok (and pid (%gone-p pid)))))
