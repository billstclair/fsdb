; -*- mode: lisp -*-

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; File System Database
;;;

(in-package :fsdb)

;; All put/get database implementations should extend db
(defclass db ()
  ())

(defun unimplemented-db-method (gf)
  (error "Unimplemented db method: ~s" gf))

(defgeneric db-get (db key &rest more-keys)
  (:method ((db db) key &rest more-keys)
    (declare (ignore key more-keys))
    (unimplemented-db-method 'db-get)))

(defgeneric (setf db-get) (value db key &rest more-keys)
  (:method (value (db db) key &rest more-keys)
    (declare (ignore value key more-keys))
    (unimplemented-db-method '(setf db-get))))

(defun db-put (db key value)
  (setf (db-get db key) value))

(defgeneric db-lock (db key)
  (:method ((db db) key)
    (declare (ignore key))
    (unimplemented-db-method 'db-lock)))

(defgeneric db-unlock (db lock)
  (:method ((db db) lock)
    (declare (ignore lock))
    (unimplemented-db-method 'db-unlock)))

(defgeneric db-contents (db &rest keys)
  (:method ((db db) &rest keys)
    (declare (ignore keys))
    (unimplemented-db-method 'db-contents)))

(defgeneric db-subdir (db key)
  (:method ((db db) key)
    (declare (ignore key))
    (unimplemented-db-method 'db-subdir)))

(defgeneric db-dir-p (db &rest keys)
  (:method ((db db) &rest keys)
    (declare (ignore keys))
    (unimplemented-db-method 'db-dir-p)))

;;;
;;; Implement the db protocol using the file system
;;;

(defparameter *default-external-format* :ISO-8859-1)

(defun make-fsdb (dir &key (external-format *default-external-format*))
  "Create an fsdb instance for the given file system directory."
  (make-instance 'fsdb :dir dir :external-format external-format))

(defclass fsdb (db)
  ((dir :initarg :dir
        :accessor fsdb-dir)
   (external-format :initarg :external-format
                    :accessor fsdb-external-format
                    :initform *default-external-format*)))

(defmethod print-object ((db fsdb) stream)
  (print-unreadable-object (db stream :type t)
    (format stream "~s" (fsdb-dir db))))

(defmethod initialize-instance :after ((db fsdb) &rest ignore)
  (declare (ignore ignore))
  (let ((dir (ensure-directory-pathname (fsdb-dir db))))
    ;;(ignore-errors (create-directory dir))
    ;;(setq dir (remove-trailing-separator (namestring (truename (fsdb-dir db)))))
    (setq dir (remove-trailing-separator (namestring (fsdb-dir db))))
    (setf (fsdb-dir db) dir)))

(defun normalize-key (key)
  (if (eql (aref key 0) #\/)
      (subseq key 1)
      key))

(defun pathname-namestring (pathname)
  (namestring (translate-logical-pathname pathname)))

(defun append-paths (&rest paths)
  (declare (dynamic-extent paths))
  (with-output-to-string (s)
    (loop for path in paths
       for pathlen = (length path)
       for last-char = #\/ then last-last-char
       for last-last-char = (if (eql pathlen 0)
                                #\/
                                (elt path (1- pathlen)))
       do
         (unless (eql last-char #\/)
           (write-char #\/ s))
         (write-string path s))))

(defmethod db-filename ((db fsdb) key)
  (if (blankp key)
      (values (fsdb-dir db) "")
      (let ((key (normalize-key key)))
        (values (append-paths (pathname-namestring (fsdb-dir db)) key)
                key))))

(defmacro with-fsdb-filename ((db filename key) &body body)
  (let ((thunk (gensym)))
    `(flet ((,thunk (,filename ,key)
              (declare (ignorable ,key))
              ,@body))
       (declare (dynamic-extent #',thunk))
       (call-with-fsdb-filename #',thunk ,db ,key))))

(defun call-with-fsdb-filename (thunk db key)
  (multiple-value-bind (filename key) (db-filename db key)
    (with-file-locked (filename)
      (funcall thunk filename key))))

(defun %append-db-keys (key &optional more-keys)
  (cond ((null more-keys) key)
        (t (when (equal key "")
             (setf key (pop more-keys)))
           (let* ((len (+ (length key)
                          (reduce #'+ more-keys :key #'length)
                          (length more-keys)))
                  (res (make-string len :element-type (array-element-type key)))
                  (i -1))
             (dolist (str (cons key more-keys))
               (unless (eql i -1) (setf (aref res (incf i)) #\/))
               (dotimes (j (length str))
                 (setf (aref res (incf i)) (aref str j))))
             res))))

(defun append-db-keys (key &rest more-keys)
  (declare (dynamic-extent more-keys))
  (%append-db-keys key more-keys))

(defmethod db-get ((db fsdb) key &rest more-keys)
  (declare (dynamic-extent more-keys))
  (let ((key (%append-db-keys key more-keys)))
    (with-fsdb-filename (db filename key)
      (let ((res (file-get-contents filename (fsdb-external-format db))))
        (and (not (equal "" res))
             res)))))

(defmethod (setf db-get) (value (db fsdb) key &rest more-keys)
  (declare (dynamic-extent more-keys))
  (let ((key (%append-db-keys key more-keys)))
    (with-fsdb-filename (db filename key)
      (if (or (null value) (equal value ""))
          (when (probe-file filename) (delete-file filename))
          (file-put-contents filename value (fsdb-external-format db))))))

(defmethod db-probe ((db fsdb) key &rest more-keys)
  (declare (dynamic-extent more-keys))
  (let ((key (%append-db-keys key more-keys)))
    (with-fsdb-filename (db filename key)
      (probe-file filename))))

(defmethod db-lock ((db fsdb) key)
  (grab-file-lock (db-filename db key)))

(defmethod db-unlock ((db fsdb) lock)
  (release-file-lock lock))

(defmacro with-db-lock ((db key) &body body)
  (let ((thunk (gensym)))
    `(flet ((,thunk () ,@body))
       (declare (dynamic-extent #',thunk))
       (call-with-db-lock #',thunk ,db ,key))))

(defun call-with-db-lock (thunk db key)
  (let ((lock (db-lock db key)))
    (unwind-protect
         (funcall thunk)
      (db-unlock db lock))))

(defun file-namestring-or-last-directory (path)
  (let ((name (pathname-name path))
        (type (pathname-type path)))
    (if (or name type)
        ;; Don't use file-namestring here. It quotes names starting with "."
        (if name
            (if type (concatenate 'string name "." type) name)
            (concatenate 'string "." type))
        (car (last (pathname-directory path))))))

(defmethod db-contents ((db fsdb) &rest keys)
  (let* ((key (if keys
                 (%append-db-keys (car keys) (cdr keys))
                 ""))
         (dir (cl-fad:list-directory (db-filename db key))))
    ;; DIRECTORY doesn't necessarily return sorted on FreeBSD
    (sort (mapcar 'file-namestring-or-last-directory dir) #'string-lessp)))

(defmethod db-subdir ((db fsdb) key)
  (make-instance 'fsdb :dir (append-paths (pathname-namestring (fsdb-dir db)) key)))

(defmethod db-dir-p ((db fsdb) &rest keys)
  (declare (dynamic-extent keys))
  (let ((key (if keys (%append-db-keys (car keys) (cdr keys)) "")))
    (with-fsdb-filename (db filename key)
      (let ((path (probe-file filename)))
        (and path (cl-fad:directory-pathname-p path))))))

;;;
;;; Multiple readers, one writer for an fsdb dir.
;;; Best if the writer doesn't run very often, as the readers
;;; busy-wait with process-wait.
;;; Pretty brittle, but I only grab the read lock
;;; around the server dispatch code and the write lock
;;; around do-audit.
;;; Maybe I should use CCL's read-write locks instead.
;;;

(defmacro with-read-locked-rwlock ((lock) &body body)
  (let ((thunk (gensym "THUNK")))
    `(flet ((,thunk () ,@body))
       (declare (dynamic-extent #',thunk))
       (call-with-read-locked-rwlock #',thunk ,lock))))

(defun call-with-read-locked-rwlock (thunk lock)
  (read-lock-rwlock lock)
  (unwind-protect
       (funcall thunk)
    (read-unlock-rwlock lock)))

(defmacro with-write-locked-rwlock ((lock &optional reading-p) &body body)
  (let ((thunk (gensym "THUNK")))
    `(flet ((,thunk () ,@body))
       (declare (dynamic-extent #',thunk))
       (call-with-write-locked-rwlock #',thunk ,lock ,reading-p))))

(defun call-with-write-locked-rwlock (thunk lock &optional reading-p)
  (write-lock-rwlock lock reading-p)
  (unwind-protect
       (funcall thunk)
    (write-unlock-rwlock lock reading-p)))

;; dir -> read-write-lock
(defvar *dir-locks*
  (make-equal-hash))

(defvar *dir-locks-lock*
  (make-lock "*dir-locks-lock*"))

(defun get-dir-lock (dir)
  (or (gethash dir *dir-locks*)
      (with-lock-grabbed (*dir-locks-lock*)
        (or (gethash dir *dir-locks*)
            (setf (gethash dir *dir-locks*) (make-read-write-lock))))))

(defmacro with-read-locked-fsdb ((fsdb) &body body)
  `(with-read-locked-rwlock ((get-dir-lock (fsdb-dir ,fsdb)))
     ,@body))

(defmacro with-write-locked-fsdb ((fsdb &optional reading-p) &body body)
  `(with-write-locked-rwlock ((get-dir-lock (fsdb-dir ,fsdb)) ,reading-p)
     ,@body))

(defun rwlock-test (&optional (iterations 3) (readers 5))
  (let ((stop nil)
        (lock (make-read-write-lock))
        (stream *standard-output*))
    (dotimes (i readers)
      (process-run-function
       (format nil "Reader ~s" i)
       (lambda (cnt)
         (loop
            (with-read-locked-rwlock (lock)
              (format stream "Start reader ~s~%" cnt)
              (sleep 0.5)
              (format stream "Stop reader ~s~%" cnt))
            (when stop (return))))
       i))
    (unwind-protect
         (dotimes (i iterations)
           (sleep 0.1)
           (with-read-locked-rwlock (lock)
             (with-write-locked-rwlock (lock t)
               (format t "Start writer~%")
               (sleep 0.1)
               (format t "Stop writer~%"))))
      (setf stop t))))

;;;
;;; A wrapper for a db that saves writes until commit
;;;

(defclass db-wrapper (db)
  ((db :initarg :db
       :accessor db-wrapper-db)
   (dirs :initform (list nil :dir)
         :initarg :dirs
         :accessor db-wrapper-dirs)
   (locks :initform nil
          :accessor db-wrapper-locks)))

(defmethod print-object ((db db-wrapper) stream)
  (print-unreadable-object (db stream :type t)
    (format stream "~s" (db-wrapper-db db))))

(defun make-db-wrapper (db)
  (make-instance 'db-wrapper :db db))

;; This doesn't protect against treating a file system directory
;; as a file or vice-versa. If you do it, you'll get an error
;; from commit-db-wrapper
(defun get-db-wrapper-cell (db key more-keys &key create-p dir-cell-p)
  (assert (not (and create-p dir-cell-p)))
  ;; Eliminate trailing slashes
  (let* ((keystr (%append-db-keys key more-keys))
         (keys (split-sequence:split-sequence
                #\/ keystr :remove-empty-subseqs t)))
    (setf keys (nreverse keys))
    (let ((file (pop keys))
          (dirs (nreverse keys))
          (parent (db-wrapper-dirs db)))
      (when (null file)
        (return-from get-db-wrapper-cell (cdr parent)))
      (dolist (dir dirs)
        (let  ((cell (assoc dir (cddr parent) :test #'equal)))
          (cond (cell
                 (when create-p
                   (assert (eq (cadr cell) :dir))))
                (create-p
                 (setf cell (list dir :dir))
                 (push cell (cddr parent)))
                (t (return-from get-db-wrapper-cell nil)))
          (setf parent cell)))
      (let ((cell (assoc file (cddr parent) :test #'equal)))
        (cond (cell
               (if dir-cell-p
                   (when (eq (cadr cell) :file)
                     (assert (not create-p))
                     (return-from get-db-wrapper-cell nil))
                   (assert (eq (cadr cell) :file))))
              (create-p
               (setf cell (list file :file))
               (push cell (cddr parent))))
        (cdr cell)))))

(defmethod db-get ((db db-wrapper) key &rest more-keys)
  (declare (dynamic-extent more-keys))
  (multiple-value-bind (val val-p)
      (apply #'db-wrapper-get db key more-keys)
    (if val-p
        val
        (apply #'db-get (db-wrapper-db db) key more-keys))))

(defun db-wrapper-get (db key &rest more-keys)
  "Returns two values, the value and whether it was found in the db-wrapper"
  (declare (dynamic-extent more-keys))
  (check-type db db-wrapper)
  (let ((cell (get-db-wrapper-cell db key more-keys)))
    (and cell (values (cdr cell) t))))

(defmethod (setf db-get) (value (db db-wrapper) key &rest more-keys)
  (declare (dynamic-extent more-keys))
  (when (equal value "")
    (setf value nil))
  (let ((cell (get-db-wrapper-cell db key more-keys :create-p t)))
    (setf (cdr cell) value)))

(defmethod db-contents ((db db-wrapper) &rest keys)
  (declare (dynamic-extent keys))
  (let ((cell-res (apply #'db-wrapper-contents db keys))
        (res (apply #'db-contents (db-wrapper-db db) keys)))
    (if cell-res
        (sort (union cell-res res :test #'equal) #'string<)
        res)))

(defun db-wrapper-contents (db &rest keys)
  (declare (dynamic-extent keys))
  (let ((cell (get-db-wrapper-cell db (car keys) (cdr keys) :dir-cell-p t)))
    (when cell
      (mapcar #'car (cdr cell)))))

(defun rollback-db-wrapper (db)
  (check-type db db-wrapper)
  (setf (db-wrapper-dirs db) (list nil :dir))
  (let ((locks (db-wrapper-locks db))
        (wrapped-db (db-wrapper-db db)))
    (setf (db-wrapper-locks db) nil)
    (dolist (key.lock locks)
      (ignore-errors
        (db-unlock wrapped-db (cdr key.lock)))))
  nil)

;; This sure conses a lot. May need to fix that at some point.
(defun commit-db-wrapper (db)
  (check-type db db-wrapper)
  (let ((wrapped-db (db-wrapper-db db))
        (cnt 0))
    (labels ((do-dir-cell (dir-cell path)
               (dolist (cell dir-cell)
                 (let ((type (cadr cell)))
                   (ecase type
                     (:dir
                      (do-dir-cell (cddr cell) (cons (car cell) path)))
                     (:file
                      (let* ((path (reverse (cons (car cell) path)))
                             (key (%append-db-keys (car path) (cdr path))))
                        (db-put wrapped-db key (cddr cell))
                        (incf cnt))))))))
      (do-dir-cell (cddr (db-wrapper-dirs db)) nil))
    (rollback-db-wrapper db)
    cnt))

;; db-wrapper locking. All locks held until commit
(defmethod db-lock ((db db-wrapper) key)
  (unless (assoc key (db-wrapper-locks db) :test #'equal)
    (let ((lock (db-lock (db-wrapper-db db) key)))
      (push (cons key lock) (db-wrapper-locks db))
      lock)))

(defmethod db-unlock ((db db-wrapper) lock)
  (declare (ignore lock)))

(defun copy-db-wrapper (db)
  (check-type db db-wrapper)
  (make-instance 'db-wrapper
                 :db (db-wrapper-db db)
                 :dirs (copy-tree (db-wrapper-dirs db))))

(defmacro with-db-wrapper ((db &optional (db-form db)) &body body)
  (check-type db symbol)
  (let ((thunk (gensym "THUNK")))
    `(flet ((,thunk (,db) ,@body))
       (declare (dynamic-extent #',thunk))
       (call-with-db-wrapper #',thunk ,db-form))))

(defun call-with-db-wrapper (thunk db)
  (let ((db (make-db-wrapper db))
        (done-p nil))
    (unwind-protect
         (multiple-value-prog1
             (funcall thunk db)
           ;; Non-local exit causes commit to be skipped.
           (commit-db-wrapper db)
           (setf done-p t))
      (unless done-p
        (rollback-db-wrapper db)))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Copyright 2009-2010 Bill St. Clair
;;;
;;; Licensed under the Apache License, Version 2.0 (the "License");
;;; you may not use this file except in compliance with the License.
;;; You may obtain a copy of the License at
;;;
;;;     http://www.apache.org/licenses/LICENSE-2.0
;;;
;;; Unless required by applicable law or agreed to in writing, software
;;; distributed under the License is distributed on an "AS IS" BASIS,
;;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;;; See the License for the specific language governing permissions
;;; and limitations under the License.
;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
