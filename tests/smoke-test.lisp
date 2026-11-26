(in-package #:task-worker-process/tests)

(deftest package-exists
  (ok (find-package '#:stack-task-worker)))
