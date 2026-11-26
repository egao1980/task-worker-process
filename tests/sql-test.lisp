(in-package #:task-worker-process/tests)

;;; 0.1.0 contract: the same runner over task-backend-sql's SQLite queue; a
;;; second connection to the file sees the outcome (another process would).

(deftest sqlite-queue-round-trip
  (let* ((dir (ensure-directories-exist
               (merge-pathnames "sql/" *test-work-root*)))
         (path (uiop:native-namestring (merge-pathnames "jobs.sqlite" dir)))
         (c1 (sql-protocol:connect :driver :sqlite3 :database-name path))
         (c2 nil))
    (unwind-protect
         (let* ((queue (task-backend-sql:make-sql-job-queue
                        :connection c1 :resource-classes '((:tiny 2))))
                (s (%supervisor queue))
                (payload '(:steps 3))
                (echo (%submit queue :echo :payload payload :resource-class :tiny))
                (prog (%submit queue :progress :payload payload :resource-class :tiny)))
           (w:run-next-job s)
           (w:run-next-job s)
           (setf c2 (sql-protocol:connect :driver :sqlite3 :database-name path))
           (let ((other (task-backend-sql:make-sql-job-queue :connection c2)))
             (ok (eq :completed (%state other echo)))
             (ok (equal (list :echo payload) (q:job-result (q:job-status other echo))))
             (ok (eq :done (q:job-result (q:job-status other prog))))
             (ok (equal '(1/3 2/3 1)
                        (mapcar #'q:job-progress-fraction (%progress other prog))))))
      (ignore-errors (sql-protocol:disconnect c1))
      (when c2 (ignore-errors (sql-protocol:disconnect c2)))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))
