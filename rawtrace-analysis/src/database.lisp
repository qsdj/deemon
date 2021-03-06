; This file is part of Deemon.

; Deemon is free software: you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation, either version 3 of the License, or
; (at your option) any later version.

; Deemon is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU General Public License for more details.

; You should have received a copy of the GNU General Public License
; along with Deemon.  If not, see <http://www.gnu.org/licenses/>.


(in-package :de.uni-saarland.syssec.analyzer.database)


(clsql:file-enable-sql-reader-syntax)


(defun extract-sql-commands (schema-path)
  (with-open-file (stream schema-path)
    (do ((line (read-line stream nil nil)
	       (read-line stream nil nil))
	 (commands nil)
	 (command-buffer nil))
	((not line) (reverse commands))
      (if (cl-ppcre:scan ";" line)
	  (progn 
	    (push (FORMAT nil "~{~a ~}" (append (reverse command-buffer) (list line))) commands)
	    (setf command-buffer nil))
	  (push line command-buffer)))))   


(defun create-database (sink-connection sink-database-schema-path)
    (do ((commands (extract-sql-commands sink-database-schema-path) (cdr commands)))
	((not commands) nil)
      (clsql:execute-command (car commands) :database sink-connection)))


(defun merge-databases (source-db-vilanoo source-db-mosgi)
  (clsql:execute-command "DELETE FROM HTTP_REQUESTS WHERE 1 = 1;" :database source-db-mosgi) 
  (copy-http-request-entries (get-all-http-request-ids source-db-vilanoo)
			     source-db-vilanoo
			     source-db-mosgi))


(defun copy-http-request-entries (id-list db-source-connection-vilanoo db-sink-connection)
  (mapcar #'(lambda(id)
              (destructuring-bind (id time request-url request-body header method-type cookies status-code)
                  (car (clsql:select [ID] [TIME] [REQUEST-URL] [REQUEST-BODY] [HEADERS] [METHOD-TYPE] [COOKIES] [STATUS-CODE]
                                     :FROM [HTTP-REQUESTS]
                                     :WHERE [= [ID] id]
                                     :database db-source-connection-vilanoo))
                (clsql:insert-records :INTO [HTTP-REQUESTS]
                                      :ATTRIBUTES '([ID] [TIME] [REQUEST-URL] [REQUEST-BODY] [HEADERS] [METHOD-TYPE] [COOKIES] [STATUS-CODE])
                                      :VALUES (list id time request-url request-body header method-type cookies status-code)
                                      :database db-sink-connection)))
          id-list))


(defun get-highest-http-request-id-entry (source-db-connection)
  (let ((numbers (clsql:select [ID] :FROM  [HTTP-REQUESTS] :database source-db-connection :flatp T)))
    (apply #'max (car numbers) (cdr numbers))))


(defun get-all-http-request-ids (source-db-connection)
  (sort (clsql:select [ID] :FROM  [HTTP-REQUESTS] :database source-db-connection :flatp T)
        #'<=))	


(defmethod commit-full-sessions (database request-db-id php-session-list)
  (dolist (session php-session-list)
    (clsql:insert-records :into [SESSIONS]
			  :ATTRIBUTES '([HTTP-REQUEST-ID] [SESSION-ID] [SESSION-STRING])
			  :VALUES (list request-db-id 
                                        (php-session:session-id session)
					(base64:string-to-base64-string (FORMAT nil "~a" session)))
			  :database database)))


(defun commit-raw-sessions (request-db-id session-list sink-connection)
  (dolist (session session-list)
    (clsql:insert-records :INTO [SESSIONS]
                          :ATTRIBUTES '([HTTP-REQUEST-ID] [SESSION-ID] [SESSION-STRING])
                          :VALUES (list request-db-id
                                        (car session)
                                        (base64:string-to-base64-string (cadr session)))
                          :database sink-connection)))


(defmethod commit-latest-diff (database request-db-id (state-trace analysis:state-trace))  
  (if (analysis:diff-history state-trace)
      (commit-latest-diff database request-db-id (car (analysis:diff-history state-trace)))))


(defmethod commit-latest-diff (database request-db-id (fhs analysis:file-diff-entry))
  (dolist (diff-entry (analysis:file-diff-entry-diffs fhs))
    (clsql:insert-records :into [CHANGED-FILES]
			  :ATTRIBUTES '([HTTP-REQUEST-ID] [FILE-PATH])
			  :VALUES (list request-db-id diff-entry)					
			  :database database)))


(defmethod commit-latest-diff (database request-db-id (shs analysis:php-session-diff-entry))
  (dolist (diff-entry (analysis:php-session-diff-entry-diffs shs))
    (clsql:insert-records :INTO [SESSION-DIFF-TREES]
			  :ATTRIBUTES '([HTTP-REQUEST-ID]
					[SESSION-ID]
					[DIFF-TREE])
			  :VALUES (list request-db-id (php-session:session-id (car diff-entry)) 
                                        (base64:string-to-base64-string (FORMAT nil "~a" diff-entry)))
			  :database database)))
				      

(defmethod commit-sql-queries (database request-db-id mysql-queries)
  (do ((query mysql-queries (cdr query))
       (counter 0 (+ counter 1)))
      ((not query) nil)
    (clsql:insert-records :INTO [SQL-QUERIES]
			  :ATTRIBUTES '([HTTP-REQUEST-ID]
					[QUERY-COUNTER]
					[QUERY-STRING])
			  :VALUES (list request-db-id counter (car query))
			  :database database)))


(defun get-all-session-entries (id db-connection)
  (mapcar #'(lambda (entries)
              (list (car entries)
                    (cl-base64:base64-string-to-string  (cadr entries))))
          (clsql:select [SESSION-NAME] [SESSION-STRING]
                        :FROM [SESSIONS]
                        :WHERE [= [HTTP-REQUEST-ID] id]
                        :database db-connection)))
		

(clsql:def-view-class xdebug-dumps ()
  ((http-request-id
    :type (integer)
    :accessor http-request-id
    :initarg :http-request-id)
   (dump-content
    :type (array)
    :initarg :dump-content)))


(defmethod get-xdebug-blob ((xdebug-dumps xdebug-dumps))
  (gzip-stream:gunzip-sequence (read (make-string-input-stream (slot-value xdebug-dumps 'dump-content)))))


(defun get-xdebug-object-entry (id db-connection)
  (caar 
   (clsql:select 'xdebug-dumps
                 :WHERE [= [HTTP-REQUEST-ID] id]
                 :database db-connection)))
  

(defun get-xdebug-entry (id db-connection)
  (let ((entry (get-xdebug-object-entry id db-connection)))
    (if entry 
        (flexi-streams:octets-to-string 
         (get-xdebug-blob entry))
        nil)))


(defparameter +query-result-buffer+ "/tmp/analysis-query-result-buffer")

(defun create-query (id)
  (with-open-file (stream +query-buffer+ :direction :output :if-exists :supersede :if-does-not-exist :create)
    (FORMAT stream "SELECT dump_content WHERE http_request_id = ~a;"
            id)))

;;Do not use in parallel
;;Do not expect great performance
(defun get-xdebug-entry-as-file-path (id db-connection)
  (let ((command (FORMAT nil "echo '~a' | sqlite3 ~a | base64 -d | gunzip > ~a"
                         (FORMAT nil "SELECT dump_content FROM xdebug_dumps WHERE http_request_id = ~a;"  id)
                         (clsql:database-name db-connection)
                         +query-result-buffer+)))
    (FORMAT T "executing command ~a~%" command)
    (trivial-shell:shell-command command)
    +query-result-buffer+))
