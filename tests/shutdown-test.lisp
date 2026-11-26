(in-package #:task-worker-process/tests)

;;; 0.1.0 contract: clean shutdown.

(deftest shutdown-finishes-short-jobs-and-kills-long-ones
  (let* ((queue (%queue))
         (s (%supervisor queue))
         (short (%submit queue :slow :payload '(:seconds 2) :resource-class :tiny))
         (long (%submit queue :sleep :resource-class :tiny)))
    (w:start-supervisor s)
    (let ((pid (%wait-for-pid queue long)))
      (ok pid)
      (ok (%wait-until (lambda () (= 2 (length (w:supervisor-running-jobs s))))
                       :timeout 60))
      (ok (eq s (w:stop-supervisor s :grace 8)))
      (ok (eq :stopped (w:supervisor-state s)))
      (ok (eq :completed (%state queue short)) "a child that finishes in the grace")
      (ok (eq :failed (%state queue long)))
      (ok (%contains (%failure queue long) "child failure (shutdown)"
                     "killed at supervisor shutdown"))
      (ok (and pid (%gone-p pid)))
      (ok (null (w:supervisor-running-jobs s))))
    ;; nothing is claimed after the stop
    (let ((late (%submit queue :echo :resource-class :tiny)))
      (sleep 1)
      (ok (eq :queued (%state queue late))))
    (ok (typep (%catch (lambda () (w:start-supervisor s))) 'w:worker-error)
        "a stopped supervisor does not restart")))

(deftest shutdown-release-leaves-the-claim-to-expire
  (let* ((queue (%queue))
         (s (%supervisor queue :lease-seconds 5 :heartbeat-interval 0.5))
         (id (%submit queue :sleep :resource-class :tiny)))
    (w:start-supervisor s)
    (let ((pid (%wait-for-pid queue id)))
      (ok pid)
      (w:stop-supervisor s :grace 0 :killed :release)
      (ok (eq :stopped (w:supervisor-state s)))
      (ok (and pid (%gone-p pid)))
      (let ((job (q:job-status queue id)))
        (ok (eq :running (q:job-state job)) "not failed")
        (q:expire-job-leases queue :now (1+ (q:job-lease-until job)))
        (ok (eq :queued (%state queue id)) "re-queued at lease expiry")))))

(deftest stop-an-idle-supervisor
  (let ((s (%supervisor (%queue))))
    (ok (eq s (w:stop-supervisor s)))
    (ok (eq :stopped (w:supervisor-state s)))
    (ok (typep (%catch (lambda () (w:stop-supervisor s :killed :maybe))) 'type-error))))
