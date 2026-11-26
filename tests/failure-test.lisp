(in-package #:task-worker-process/tests)

;;; 0.1.0 contract: children that die or hang fail their job only.

(deftest heap-exhaustion-fails-only-that-job
  (let* ((queue (%queue))
         (s (%supervisor queue))
         (hog (%submit queue :hog :resource-class :tiny))
         (next (%submit queue :echo :payload :after :resource-class :tiny)))
    (w:run-next-job s)
    (ok (eq :failed (%state queue hog)))
    (ok (%contains (%failure queue hog) "child failure (heap-exhausted)"
                   (format nil "heap exhausted (~d MB)" *tiny-mb*)))
    (w:run-next-job s)
    (ok (eq :completed (%state queue next)) "the next job still runs")
    (ok (equal '(:echo :after) (q:job-result (q:job-status queue next))))))

(deftest crash-fails-the-job
  (let* ((queue (%queue))
         (s (%supervisor queue))
         (id (%submit queue :crash :resource-class :tiny)))
    (w:run-next-job s)
    (ok (eq :failed (%state queue id)))
    (ok (%contains (%failure queue id) "child failure (exit)" "exited with code 3"))))

(deftest timeout-kills-the-child
  (let* ((queue (%queue))
         (s (%supervisor queue :registry (%registry '(:sleep :timeout 8))))
         (id (%submit queue :sleep :resource-class :tiny))
         (start (get-internal-real-time))
         (wait (%spawn (lambda () (w:run-next-job s))))
         (pid (%wait-for-pid queue id)))
    (ok pid "the child reported its pid")
    (multiple-value-bind (job err done) (funcall wait)
      (declare (ignore job))
      (ok done)
      (ok (null err)))
    (ok (< (/ (- (get-internal-real-time) start) internal-time-units-per-second) 30)
        "killed at the timeout, not after the 600 s sleep")
    (ok (eq :failed (%state queue id)))
    (ok (%contains (%failure queue id) "child failure (timeout)" "timed out after 8 s"))
    (ok (and pid (%gone-p pid)) "the process is gone")
    (ok (null (w:supervisor-running-jobs s)))))
