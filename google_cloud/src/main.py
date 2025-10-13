import os
import json
import re
import logging
import functions_framework
import google.auth
from google.auth.transport.requests import AuthorizedSession
from google.cloud import logging as cloud_logging


CLOUD_RUN_JOB_ID = os.environ.get("CLOUD_RUN_JOB_ID")

cloud_logging_client = cloud_logging.Client()
cloud_logging_client.setup_logging()
logger = logging.getLogger(__name__)


def run_cloud_run_job(request):
    """
    Cloud FunctionsでCloud Run Jobを起動
    """
    try:
        body = request.get_json(silent=True) or {}
        task_count = body.get("task_count", 1)
        trocco_pipeline_definition_id = body.get("trocco_pipeline_definition_id")
        task_execution_mode = body.get("task_execution_mode", "single_job")

        if task_count is None:
            return ("task_count parameter is required", 400)
        try:
            task_count = int(task_count)
        except ValueError:
            return ("task_count must be an integer", 400)
        if task_count <= 0:
            return ("task_count must be a positive integer", 400)

        credentials, project = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        authed_session = AuthorizedSession(credentials)
        base_url = f"https://run.googleapis.com/v2/{CLOUD_RUN_JOB_ID}"

        # ref: https://cloud.google.com/run/docs/reference/rest/v2/projects.locations.jobs/get
        existing_job_config = authed_session.get(base_url)
        if existing_job_config.status_code != 200:
            return (
                f"Failed to get: {existing_job_config.text}",
                existing_job_config.status_code,
            )

        container_config = existing_job_config.json()["template"]["template"][
            "containers"
        ]
        additional_env = []

        if (
            trocco_pipeline_definition_id != 0
            and trocco_pipeline_definition_id is not None
        ):
            additional_env.append(
                {
                    "name": "TROCCO_PIPELINE_DEFINITION_ID",
                    "value": trocco_pipeline_definition_id,
                }
            )

        # ref: https://cloud.google.com/run/docs/reference/rest/v2/projects.locations.jobs/run
        execution_url = f"{base_url}:run"
        body = {
            "overrides": {
                "containerOverrides": {
                    "name": container_config[0]["name"],
                    "env": container_config[0].get("env", []) + additional_env,
                },
                "taskCount": task_count if task_execution_mode == "single_job" else 1,
            }
        }

        if task_execution_mode == "single_job":
            response = authed_session.post(execution_url, json=body)
            if response.status_code != 200:
                return (f"Failed to execute: {response.text}", response.status_code)

            return json.dumps(
                {
                    "status": "success",
                    "task_count": task_count,
                    "executed_result": response.json(),
                }
            )
        else:
            execution_results = []
            for _ in range(task_count):
                response = authed_session.post(execution_url, json=body)
                if response.status_code != 200:
                    return (f"Failed to execute: {response.text}", response.status_code)
                execution_results.append(response.json())

            return json.dumps(
                {
                    "status": "success",
                    "task_count": task_count,
                    "executed_results": execution_results,
                }
            )

    except Exception as e:
        return (str(e), 500)


def list_cloud_run_job_executions(request):
    """
    Cloud FunctionsでCloud Run Job Executionの一覧を取得
    """
    try:
        page_size = request.args.get("page_size", type=int)
        page_token = request.args.get("page_token", type=str)
        show_deleted_str = request.args.get("show_deleted", type=str)
        show_deleted = show_deleted_str.lower() == "true" if show_deleted_str else False

        credentials, project = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        authed_session = AuthorizedSession(credentials)
        # ref: https://cloud.google.com/run/docs/reference/rest/v2/projects.locations.jobs.executions/list
        url = f"https://run.googleapis.com/v2/{CLOUD_RUN_JOB_ID}/executions"

        params = {}
        if page_size is not None:
            params["pageSize"] = page_size
        if page_token is not None:
            params["pageToken"] = page_token
        if show_deleted:
            params["showDeleted"] = show_deleted

        response = authed_session.get(url, params=params)
        if response.status_code != 200:
            return (f"Failed to get: {response.text}", response.status_code)

        return json.dumps(
            {
                "status": "success",
                "executions": response.json(),
            }
        )

    except Exception as e:
        return (str(e), 500)


def list_cloud_run_job_execution_tasks(request):
    """
    Cloud FunctionsでCloud Run Job Execution Taskの一覧を取得
    """
    try:
        page_size = request.args.get("page_size", type=int)
        page_token = request.args.get("page_token", type=str)
        show_deleted_str = request.args.get("show_deleted", type=str)
        show_deleted = show_deleted_str.lower() == "true" if show_deleted_str else False

        path = request.path
        match = re.match(r"^/executions/([^/]+)/tasks/list$", path)
        execution_id = match.group(1)

        credentials, project = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        authed_session = AuthorizedSession(credentials)
        # ref: https://cloud.google.com/run/docs/reference/rest/v2/projects.locations.jobs.executions.tasks/list
        url = f"https://run.googleapis.com/v2/{CLOUD_RUN_JOB_ID}/executions/{execution_id}/tasks"

        params = {}
        if page_size is not None:
            params["pageSize"] = page_size
        if page_token is not None:
            params["pageToken"] = page_token
        if show_deleted:
            params["showDeleted"] = show_deleted

        response = authed_session.get(url, params=params)
        if response.status_code != 200:
            return (f"Failed to get: {response.text}", response.status_code)

        return json.dumps(
            {
                "status": "success",
                "tasks": response.json(),
            }
        )

    except Exception as e:
        return (str(e), 500)


@functions_framework.http
def cloud_run_jobs_manager_handler(request):
    """
    Cloud Functions のエントリポイント
    """
    try:
        # for debugging
        logging.info(f"Method: {request.method}")
        logging.info(f"Path: {request.path}")
        logging.info(f"Headers: {request.headers}")
        logging.info(f"Query params: {request.args}")
        logging.info(f"Body: {request.get_json(silent=True)}")

        request_path = request.path
        if not request_path:
            return ("Cannot get path", 400)

        if request_path.startswith("/run"):
            return run_cloud_run_job(request)

        elif request_path.startswith("/executions/list"):
            return list_cloud_run_job_executions(request)

        elif re.match(r"^/executions/[^/]+/tasks/list$", request_path):
            return list_cloud_run_job_execution_tasks(request)

        else:
            return ("Unknown path", 404)

    except Exception as e:
        return (str(e), 500)
