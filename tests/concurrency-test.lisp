(in-package #:task-worker-process/tests)

;;; 0.1.0 contract: the claim loop; concurrency comes from the queue's
;;; resource classes.

(deftest resource-class-bounds-concurrency
  (let* ((queue (%queue '(:pair 2)))
         (s (%supervisor queue :heap-sizes '((:pair . 256))))
         (ids (loop repeat 3
                    collect (%submit queue :slow :payload '(:seconds 3)
                                                 :resource-class :pair)))
         (most 0))
    (ok (eq s (w:start-supervisor s)))
    (ok (eq :running (w:supervisor-state s)))
    (ok (eq s (w:start-supervisor s)) "starting a running supervisor is a no-op")
    (ok (%wait-until (lambda ()
                       (setf most (max most (length (w:supervisor-running-jobs s))))
                       (every (lambda (id) (eq :completed (%state queue id))) ids))
                     :timeout 90)
        "every job completes")
    (ok (= 2 most) "two children at once, never three")
    (w:stop-supervisor s :grace 5)
    (ok (eq :stopped (w:supervisor-state s)))))
