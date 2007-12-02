;;;; Front end handling for docutils
;;;; Copyright (C) 2005 John A.R. Williams <J.A.R.Williams@jarw.org.uk>
;;;; Released under the GNU General Public License (GPL)
;;;; See <http://www.gnu.org/copyleft/gpl.html> for license details
;;;;
;;;; $Id: publisher.lisp,v 1.16 2007/08/03 08:16:52 willijar Exp $

;;;; The processing chain is as follows
;;;; source - a source of characters for the processor
;;;; reader - reads data from source to produce a complete document
;;;;          transform - used by readers for pending actions
;;;; writer - formats a document and writes to output
;;;; destination - a destination stream for the formatted document characters

(in-package :docutils)

(defparameter *revision* '(0 1 1)
  "(major minor micro) version number. The micro number is bumped for API
changes, for new functionality, and for interim project releases.  The minor
number is bumped whenever there is a significant project release.  The major
number will be bumped when the project is feature-complete, and perhaps if
there is a major change in the design.")

(defgeneric get-settings(source)
  (:documentation "Return the settings has for this source"))

(defgeneric new-document(source)
  (:documentation "Create and return a new empty document tree (root node).")
  (:method(source)
    (make-instance 'docutils.nodes:document :settings (get-settings nil)))
  (:method((source pathname))
    (make-instance 'docutils.nodes:document
                   :source-path source
                   :settings (get-settings source))))

(defgeneric read-document(source reader)
  (:documentation "Create and read a new document using reader from source"))

(defgeneric write-document(writer document destination)
  (:documentation "Write document out to destination using given writer"))

(defgeneric write-part(writer part output-stream)
  (:documentation "Write a document part from writer to an output stream."))

(defgeneric transform(transform)
  (:documentation "Apply a given transform to its' document node"))

(defgeneric (setf document)(document component)
  (:documentation "Set the document to be processed and reset the component"))

(defgeneric do-transforms(transforms document)
  (:documentation "Apply the transformations to this document in
order. Any system messages are added into a dedicated section at the
end of the document"))

(defgeneric transforms(reader)
  (:documentation "Return a list of the default transforms class names to be
applied after parsing"))

;;; -------------------------------------------------
;;; Transform api used by readers for pending actions
;;; -------------------------------------------------

(defvar *unknown-reference-resolvers* nil
"List of functions to try to resolve unknown references.  Unknown
    references have a 'refname' attribute which doesn't correspond to any
    target in the document.  Called when FinalCheckVisitor is unable to find a
    correct target.  The list should contain functions which will try to
    resolve unknown references, with the following signature::

        (defun reference_resolver(node)
           \"Returns boolean: true if resolved, false if not.\"
          )")


(defvar *transform-counter* 0
  "Used to ensure transforms of the same priority maintain their order")

(defclass transform()
  ((priority :initform 500 :initarg :priority :reader priority
             :documentation
             "Numerical priority of this transform, 0 through 999.")
   (order :initform (incf *transform-counter*) :reader order)
   (node :initarg :node :reader node
         :documentation "The node at which this transform is to start"))
  (:documentation "Docutils transform component abstract base class."))

(defmethod print-object((transform transform) stream)
  (print-unreadable-object (transform stream :type t :identity t)
    (format stream "~A:~A" (slot-value transform 'priority)
            (slot-value transform 'order))))

(defmethod priority((f function)) 950)
(defmethod order((f function)) 0)
(defmethod transform((f function)) (funcall f *document*))

(defun transform-cmp(a b)
  "Transforms compared by priority and order in which created"
  (let ((pa (priority a))
        (pb (priority b)))
    (or (< pa pb)
        (and (= pa pb)
             (< (order a) (order b))))))

;;; -------------------------------------------------
;;; The standard reader implementation base
;;; -------------------------------------------------

(defclass reader()
  ()
  (:documentation "Base classes to produce a document from input"))

(defvar *pending-transforms* nil)

(defun add-transform(transform) (push transform *pending-transforms*))

(defmethod read-document :around (source (reader reader))
  (let ((*pending-transforms* (transforms reader))
        (*document* (new-document source)))
    (call-next-method)
    (do-transforms *pending-transforms* *document*)
    *document*))

(defun handle-transform-condition(e document &optional messages)
  "Deal with transform errors, reporting messages in messages node if
supplied"
  (let ((report-level (setting :report-level document))
        (halt-level  (setting :halt-level document))
        (msg (make-node 'system-message e)))
    (when messages (add-child messages msg))
    (when (error-node e)
      (add-backref msg (set-id (error-node e) document)))
    (when (>= (error-severity e) report-level)
      (format *error-output*
              "~A~@[ line ~A~] ~A~%" ;; and print
              (error-level e)
              (error-line e)
              (error-message e)))
    (if (>= (error-severity e) halt-level)
        (error e)
        (invoke-restart 'system-message msg))))

(defun system-messages-section(document)
  "Return (and if necessary add) a system message section node at the
end of the document"
  (let ((lastnode (child document (1- (number-children document))))
        (title  "Docutils System Messages"))
    (if (string-equal (title lastnode) title)
        lastnode
        (let ((section (make-node 'section)))
           (add-child document section)
           (add-child section (make-node 'title title))
           section))))

(defmethod do-transforms((transforms list) document)
  (unless (= 0 (number-children document))
    (let ((messages (system-messages-section document)))
      (handler-bind
          ((markup-condition
            #'(lambda(e) (handle-transform-condition e document messages))))
        (dolist(transform
                 (sort (mapcar
                        #'(lambda(transform)
                            (etypecase transform
                              (transform transform)
                              (symbol
                               (make-instance transform :node *document*))
                              (function
                               (make-instance
                                'docutils.transform:simple-transform
                                :function transform
                                :node *document*))))
                        transforms)
                       #'transform-cmp))
          (transform transform)))
      (when (< (number-children messages) 2)
        (remove-node messages)))))


;;; -------------------------------------------------
;;; The standard writer implementation base
;;; -------------------------------------------------

(defclass writer()
  ((parts :type list :reader parts :initarg :parts
          :documentation "List of slot names for component parts in
the output. The writer should accumulate strings on each part using
push.")
   (document :initform nil :reader document
             :documentation "The current document"))
  (:documentation "Base Class for writing a document"))

(defmethod write-document  ((writer writer) document (os stream))
  (setf (document writer) document)
  (dolist(part (parts writer))
    (write-part writer (if (symbolp part) part (car part)) os)))

(defmethod write-part((writer writer) (part symbol) (os stream))
  (dolist(s (slot-value writer part))
    (etypecase s
      (string (write-string s os))
      (character (write-char s os)))))

(defmethod (setf document)(document (writer writer))
  "Sets current document - updating writer parts if need be"
  (unless (and (slot-boundp writer 'document)
               (eql (slot-value  writer 'document) document))
    (setf (slot-value  writer 'document) document)
    (dolist(part (parts writer))
      (if (symbolp part)
          (setf (slot-value writer part) nil)
          (setf (slot-value writer (car part)) (reverse (cdr part)))))
    (visit-node writer document)
    (dolist(part (parts writer))
      (let ((part (if (symbolp part) part (car part))))
        (setf (slot-value writer part) (nreverse (slot-value writer part)))))))

(defgeneric supports-format(writer format)
  (:documentation "Returns true if given writer supports a specific format"))

(defgeneric visit-node(writer entity)
  (:documentation "Process entity for writer where entity is any entity
in the document."))

(defvar *current-writer* nil "Writer currently processing document")
(defvar *current-writer-part* nil "current destination writer slot")

(defmethod visit-node :around ((writer writer) (entity document))
  (let ((*document* (document writer))
        (*current-writer* writer))
    (call-next-method)))

(defmacro with-part((part-name) &body body)
  `(let ((*current-writer-part* ',part-name))
    ,@body))

(defun part-append(&rest values)
  (setf (slot-value *current-writer* *current-writer-part*)
        (nconc (nreverse values)
               (slot-value *current-writer* *current-writer-part*))))

(defun part-prepend(&rest values)
  (setf (slot-value *current-writer* *current-writer-part*)
        (nconc (slot-value *current-writer* *current-writer-part*)
               (nreverse values))))

(defmethod visit-node :around (writer entity)
  (restart-case
      (call-next-method)
    (continue()
      :report (lambda(stream)
                (format stream "Continue processing after ~S" entity)))))

(defmethod visit-node (writer (entity element))
  "By default visit children of an element. throw to :skip-siblings to not
process further children"
  (catch :skip-siblings
    (with-children(child entity) (visit-node writer child))))

;;; -------------------------------------------------
;;; Processing settings and configuration handling
;;; -------------------------------------------------

(defvar *standard-config-files*
  `(#p"/etc/cl-docutils.conf"
    ,(merge-pathnames ".cl-docutils.conf" (user-homedir-pathname)))
  "List of standard docutils configuration files")

(defvar *config-files-read* nil "List of configuration files already read.")
(defvar *settings-spec* nil "List of configuration parameters")

(defun register-settings-spec(new-spec)
  (dolist(item new-spec)
    (let ((old (assoc item *settings-spec*)))
      (if old
          (rplacd old (cdr new-spec))
          (push item *settings-spec*)))))

(defmethod get-settings((document-path pathname))
  (let ((*standard-config-files*
         (cons (merge-pathnames "cl-docutils.conf" document-path)
               *standard-config-files*)))
    (call-next-method)))

(defmethod get-settings(entity)
  "Update document settings a settings spec"
  (declare (ignore entity))
  (let ((settings (make-hash-table))
        (*config-files-read* nil)
        (specs *settings-spec*))
    ;;; set defaults
    (dolist(spec specs) (setf (gethash (first spec) settings) (third spec)))
    ;; the override from config files
    (dolist(fname *standard-config-files*)
      (merge-settings settings (read-settings fname specs)))
    settings))

(defun merge-settings(destination newsettings)
  (maphash #'(lambda(k v) (setf (gethash k destination) v))
           newsettings))

(defun read-settings(fname specs)
  (unless (member fname *config-files-read* :test #'equal)
    (let ((settings (make-hash-table)))
      (when (probe-file fname)
        (with-open-file(is fname :direction :input)
          (push fname *config-files-read*)
          (do((line (read-line is nil) (read-line is nil)))
             ((not line))
            (when (and (> (length line) 1) (not (line-blank-p line))
                       (not (char= (char line 0) #\#)))
              (let ((p (position #\: line)))
                (if p
                    (let* ((name (intern
                                  (string-upcase (strip (subseq line 0 p)))
                                  :keyword))
                           (value (if (< p (1- (length line)))
                                      (lstrip (subseq line (1+ p)))
                                      ""))
                           (spec (assoc name specs)))
                      (if (eql name :config)
                          (merge-settings
                           settings
                           (read-settings (pathname (strip value)) specs))
                          (setf (gethash name settings)
                                (if spec
                                    (restart-case
                                        (jarw.parse:parse-input
                                         (second spec)  value)
                                      (use-value(&optional (value (third spec)))
                                        :report (lambda(s)
                                                  (format
                                                   s "Use value <~A> for ~S"
                                                   value name))
                                        value))
                                    value))))
                    (warn "~S is not a valid specification line in <~A>"
                          line fname)))))))
      settings)))

(register-settings-spec ;; base settings spec
 `((:generator
    boolean t
    "Include a 'Generated by Docutils' credit and link at the end of
the document.")
   (:datestamp symbol :rfc2822 "Include the date/time at the end of
the document (UTC) is specified format.")
   (:source-link
    boolean nil
    "Include a 'View document source' link (relative to destination).")
   (:source-url
    (string :nil-allowed t) nil
    "Use the supplied <URL> verbatim for a 'View document source'
link; implies --source-link.")
   (:toc-backlinks
    (member :type (symbol :nil-allowed t) :set (:top :entry nil)) :entry
    "Enable backlinks from section headers to top of table of contents
or entries (default.")
   (:footnote-backlinks
    boolean t
    "Enable backlinks from footnotes and citations to their
references. This is the default.")
   (:section-numbering
    boolean t
    "Enable Docutils section numbering")
   (:report-level
    (integer :min 0 :max 10) 4
    "Set verbosity threshold; report system messages at or higher than level")
   (:halt-level
    (integer :min 0 :max 10) 8
    "Set the threshold (<level>) at or above which system messages
cause a halt")
   (:warnings
    '(pathname :nil-allowed t) ,*error-output*
    "Send the output of system messages (warnings) to <file>.")
   (:language
    string "en"
    "Specify the language of input text (ISO 639 2-letter identifier).")
   (:record-dependencies
    '(pathname :nil-allowed t) nil
    "Write dependencies (caused e.g. by file inclusions) to <file>.")
   (:search-path
    (jarw.parse::pathnames :nil-allowed t :wild-allowed t) nil
    "Path to search for paths (after source path)")
   (:config
    '(pathname :nil-allowed t) nil
    "Read configuration settings from <file> if it exists.")
   (:version
    boolean nil
    "Show this program's version number and exit.")
   (:help
    boolean nil
    "Show help message and exit.")))