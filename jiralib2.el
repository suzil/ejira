;;; jiralib2.el -- Provide connectivity to JIRA REST services.

;; Copyright (C) 2017 Henrik Nyman

;; Author: Henrik Nyman <henrikjohannesnyman@gmail.com>
;; URL: https://github.com/nyyManni/ejira
;; Keywords: calendar, data, org, jira
;; Version: 1.0
;; Package-Requires: ((org "8.3") (ox-jira) (language-detection) (s "1.0"))

;; This file is NOT part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This file provides a programatic interface to JIRA.  It provides access to
;; JIRA from other programs, but no user level functionality.

;; jiralib2.el uses cookie authentication instead of basic auth for performance
;; reasons. JIRA API has an artificial delay of ~second in basic auth queries.
;; The session cookie is stored in an Emacs global variable, and it is
;; automatically used in each query. If the user has not logged in, or the
;; session has expired, a new login is performed and the password queried from
;; the user. jiralib2 DOES NOT store user's password anywhere like jiralib did.
;; Only the session token is saved, and user credentials cannot be extracted
;; from it.

;; Jira References:

;; Primary reference (on current Jira, only REST is supported):
;; https://docs.atlassian.com/jira/REST/cloud/

;;; Code:
(eval-when-compile (require 'cl))
(require 'request)
(require 'json)
(require 'url-parse)

(defgroup jiralib2 nil
  "Jiralib2 customization group."
  :group 'applications)

(defcustom jiralib2-url "http://localhost:8081/"
  "The address of the jira host."
  :type 'string
  :group 'jiralib2)

(defun jiralib2--verify-status (response)
  "Check status code of RESPONSE, return data or throw an error."
  (let ((status-code (request-response-status-code response)))
    (cond ((not status-code)
           (user-error "Login failed: Could not reach the server"))

          ((= status-code 401)
           (user-error "Login failed: invalid password"))

          ;; Several failed password attempts require you to answer
          ;; a captcha, that must be done in the browser.
          ((= status-code 403)
           (user-error "Login denied: please login in the browser"))

          ((= status-code 404)
           (user-error "Login failed: Wrong URL path"))

          ((and (>= status-code 400) (< status-code 500))
           (user-error "Login failed: invalid request"))

          ((>= status-code 500)
           (error "Login failed: Server error"))

          ;; status codes 200 - 399 should be ok.
          (t (request-response-data response)))))

(defun jiralib2--api-call (path args)
  "Do a call to PATH with ARGS to the API."
  (when (not (boundp 'jiralib2-user-login-name))
    (user-error "jiralib2-user-login-name must be defined"))

  (when (not (boundp 'jiralib2-api-token))
    (user-error "jiralib2-api-token must be defined"))
  
  (apply #'request (concat jiralib2-url path)
         :headers `(("Content-Type" . "application/json")
                    ("Authorization" .
		     ,(concat "Basic "
			      (base64-encode-string
			       (concat
				jiralib2-user-login-name
				":"
				jiralib2-api-token)))))
         :sync t
         :parser 'json-read
         args))

(defun jiralib2-api-call (path &rest args)
  "Call the Jira REST API and make sure the response is OK."
  (let ((response (jiralib2--api-call path args)))

    (unless (request-response-status-code response)
      (user-error "Call failed: Could not reach the server"))

    (jiralib2--verify-status response)))

(defun jiralib2-get-user-info ()
  "Fetch information on currently logged in user."
  (jiralib2-api-call "/rest/api/2/myself"))

(defun jiralib2-get-issue (issue-key)
  "Get the issue with key ISSUE-KEY."
  (jiralib2-api-call (format "/rest/api/2/issue/%s" issue-key)))

(defun jiralib2-add-comment (issue-key body)
  "Add comment to issue ISSUE-KEY with contents BODY."
  (jiralib2-api-call (format "/rest/api/2/issue/%s/comment" issue-key)
                     :type "POST"
                     :data (json-encode `((body . ,body)))))


(defun jiralib2-delete-comment (issue-key comment-id)
  "Remove comment COMMENT-ID from issue ISSUE-KEY."
  (jiralib2-api-call (format "/rest/api/2/issue/%s/comment/%s"
                             issue-key comment-id)
                     :type "DELETE"))

(defun jiralib2-edit-comment (issue-key comment-id body)
  "Update comment COMMENT-ID from issue ISSUE-KEY with body BODY."
  (jiralib2-api-call (format "/rest/api/2/issue/%s/comment/%s"
                             issue-key comment-id)
                     :type "PUT"
                     :data (json-encode `((body . ,body)))))

(defvar *jiralib2-users-cache* nil)
(defun jiralib2-get-users (project-key)
  "Return assignable users information given the PROJECT-KEY."
  (or *jiralib2-users-cache*
      (jiralib2-api-call
       (format "/rest/api/2/user/assignable/search?project=%s&maxResults=10000"
               project-key))))

(defun jiralib2-assign-issue (issue-key username)
  "Assign issue with ISSUE-KEY to USERNAME."
  (jiralib2-api-call (format "/rest/api/2/issue/%s/assignee" issue-key)
                     :type "PUT"
                     :data (json-encode `((name . ,username)))))

(defun jiralib2-do-jql-search (jql &optional limit)
  "Run a JQL query and return the list of issues that matched.
LIMIT is the maximum number of queries to return.  Note that JIRA
has an internal limit of how many queries to return, as such, it
might not be possible to find *ALL* the issues that match a
query."
  (unless (or limit (numberp limit))
    (setq limit 100))
  (append
   (cdr
    (assoc 'issues
           (jiralib2-api-call "/rest/api/2/search"
                              :type "POST"
                              :data (json-encode
                                     `((jql . ,jql)
                                       (maxResults . ,limit))))))
   nil))


(defun jiralib2-get-actions (issue-key)
  "Get available actions for the issue ISSUE-KEY.
The issues are returned as a list of ((name . <name>) (id . <id>)) alists."
  (mapcar
   (lambda (trans)
     `(,(cdr (assoc 'id trans)) . ,(cdr (assoc 'name trans))))
   (cdadr
    (jiralib2-api-call (format "/rest/api/2/issue/%s/transitions"
                               issue-key)))))

(defun jiralib2-do-action (issue-key action-id)
  "Move the issue ISSUE-KEY to another state with action ACTION-ID."
  (jiralib2-api-call (format "/rest/api/2/issue/%s/transitions" issue-key)
                     :type "POST"
                     :data (json-encode `((transition . ((id . ,action-id)))))))


(defun jiralib2-get-worklog (issue-key &optional only-mine)
  "Get worklogs of the issue ISSUE-KEY.
With ONLY-MINE set to t, only return worklogs logged by me."
  (jiralib2-api-call (format "/rest/api/2/issue/%s/worklog" issue-key)))

(defun jiralib2-add-worklog (issue-key timestamp seconds message)
  "Add a worklog to issue ISSUE-KEY with message MESSAGE.
Use TIMESTAMP as start time and SECONDS as amount of logged work in seconds."
  (jiralib2-api-call (format "/rest/api/2/issue/%s/worklog" issue-key)
                     :type "POST"
                     :data (json-encode `((comment . ,message)
                                          (started . ,timestamp)
                                          (timeSpentSeconds . ,seconds)))))

(defvar *jiralib2-projects-cache* nil)
(defun jiralib2-get-projects ()
  "Get a list of all projects."
  (or *jiralib2-projects-cache*
      (setq *jiralib2-projects-cache*
            (jiralib2-api-call "/rest/api/2/project"))))

(defvar *jiralib2-issuetypes-cache* nil)
(defun jiralib2-get-issuetypes ()
  "Get a list of all projects."
  (or *jiralib2-issuetypes-cache*
      (setq *jiralib2-issuetypes-cache*
            (jiralib2-api-call "/rest/api/2/issuetype"))))

(defun jiralib2-create-issue (project-id summary description)
  "Create a new issue into project PROJECT-ID with SUMMARY and DESCRIPTION."
  (jiralib2-api-call "/rest/api/2/issue/"
                     :type "POST"
                     :data (json-encode
                            `((fields . ((project . ,project-id)
                                         (summary . ,summary)
                                         (description . ,description)))))))

(defun jiralib2-update-summary-description (issue-id summary description)
  "Change the summary and description of issue ISSUE-ID to SUMMARY and DESCRIPTION."
  (interactive)
  (jiralib2-api-call (format "/rest/api/2/issue/%s" issue-id)
                     :type "PUT"
                     :data (json-encode
                            `((fields . ((description . ,description)
                                         (summary . ,summary)))))))


(provide 'jiralib2)
;;; jiralib2.el ends here
