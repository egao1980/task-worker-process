(in-package #:task-worker-process/tests)

;;; 0.1.0 contract: real child SBCLs (default command, inherited registry,
;;; fixture handlers). Results, progress, heap sizes, handler errors.

(deftest result-round-trip
  (let* ((queue (%queue))
         (s (%supervisor queue))
         (payload (list :text (format nil "héllo~%second line") :n 42 :x 1.5d0
                        :ratio 3/4 :v #(1 2 3) :sym :key :nested '((1 2) ("a"))))
         (id (%submit queue :echo :payload payload :resource-class :tiny)))
    (ok (null (w:run-next-job (%supervisor (%queue))))
        "nothing to claim → NIL")
    (let ((job (w:run-next-job s)))
      (ok (eq :completed (q:job-state job)))
      (ok (equalp (list :echo payload) (q:job-result job))))
    (ok (equalp (list :echo payload) (q:job-result (q:job-status queue id))))
    (ok (= 1 (q:job-attempts (q:job-status queue id))))
    (ok (null (w:supervisor-running-jobs s)))))

(deftest only-registered-kinds-are-claimed
  (let* ((queue (%queue))
         (s (%supervisor queue :registry (let ((r (w:make-handler-registry)))
                                           (w:define-job-handler
                                            r :echo (%h 'echo)
                                            :systems (list *fixture-system*))
                                           r)))
         (foreign (%submit queue :not-ours))
         (ours (%submit queue :echo :payload 1)))
    (let ((job (w:run-next-job s)))
      (ok (equal ours (q:job-id job))))
    (ok (null (w:run-next-job s)))
    (ok (eq :queued (%state queue foreign)))))

(deftest progress-relayed-in-order
  (let* ((queue (%queue))
         (s (%supervisor queue :worker-id "progress-worker"))
         (id (%submit queue :progress :payload '(:steps 5) :resource-class :tiny)))
    (w:run-next-job s)
    (ok (eq :completed (%state queue id)))
    (ok (eq :done (q:job-result (q:job-status queue id))))
    (let ((events (%progress queue id)))
      (ok (= 5 (length events)))
      (ok (equal '(1/5 2/5 3/5 4/5 1) (mapcar #'q:job-progress-fraction events)))
      (ok (equal (loop for i from 1 to 5 collect (format nil "step ~d" i))
                 (mapcar #'q:job-progress-message events)))
      (ok (every (lambda (e) (equal "step" (q:job-progress-phase e))) events))
      (ok (every (lambda (e) (equal "progress-worker" (q:job-progress-worker-id e)))
                 events)))
    ;; all progress lies between the claim and the completion
    (let ((types (mapcar (lambda (e)
                           (if (q:job-progress-p e) :p (q:job-transition-to e)))
                         (q:job-events queue id))))
      (ok (equal '(:queued :running :p :p :p :p :p :completed) types)))))

(deftest heap-size-follows-the-resource-class
  (let* ((queue (%queue))
         (s (%supervisor queue))
         (small (%submit queue :heap-size :resource-class :small))
         (plain (%submit queue :heap-size)))
    (w:run-next-job s)
    (w:run-next-job s)
    (ok (eql *small-mb* (q:job-result (q:job-status queue small))))
    (ok (eql *default-mb* (q:job-result (q:job-status queue plain))))))

(deftest handler-error-fails-the-job
  (let* ((queue (%queue))
         (s (%supervisor queue))
         (id (%submit queue :fail :payload "kaput" :resource-class :tiny)))
    (w:run-next-job s)
    (ok (eq :failed (%state queue id)))
    (ok (%contains (%failure queue id) "child failure (handler-error)" "boom: kaput"))))
