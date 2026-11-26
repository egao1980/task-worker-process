;;; Test-only handlers, loaded by the child Lisps the tests start (found
;;; through the source registry the children inherit). Never published.
(defsystem "task-worker-process-test-handlers"
  :version "0.1.0"
  :description "Job handlers for the task-worker-process tests"
  :license "MIT"
  :depends-on ()
  :components ((:file "handlers")))
