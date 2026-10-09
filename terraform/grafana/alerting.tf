# #49: one alert, as code. A lab-api pod in push or gitops that stays not-ready for 2
# minutes sends an email; it sends another when it recovers.
#
# Signal: kube_pod_status_ready{condition="false"} from kube-state-metrics, scraped by
# Alloy every 30 s (#48). The value is 1 while a pod's Ready condition is False, 0 while
# it's True. Readiness, not liveness: a pod can be up (/health 200) and still out of
# traffic (/ready 503, draining, #29), which is exactly what users notice.

# The recipient is personal data and the repository is public: it lives in SSM
# (a plain String, not a secret) and only its parameter name is in git.
data "aws_ssm_parameter" "alert_email" {
  name = "/k3s-gitops-lab/grafana-cloud/alert-email"
}

# Folder permissions in this stack are per folder: the service account can read and write
# the stack's built-in "GrafanaCloud" folder, and create folders. A top-level folder it
# creates is NOT readable by it afterwards (403 folders:read; see the #49 note). A folder
# nested inside "GrafanaCloud" inherits that folder's permissions, so it can be managed.
data "grafana_folder" "grafana_cloud" {
  title = "GrafanaCloud"
}

resource "grafana_folder" "lab" {
  title             = "k3s-gitops-lab alerts"
  parent_folder_uid = data.grafana_folder.grafana_cloud.uid
}

resource "grafana_contact_point" "email" {
  name = "k3s-gitops-lab email"

  email {
    addresses               = [data.aws_ssm_parameter.alert_email.value]
    single_email            = true
    disable_resolve_message = false
  }
}

resource "grafana_rule_group" "lab_api" {
  name             = "lab-api"
  folder_uid       = grafana_folder.lab.uid
  interval_seconds = 30

  rule {
    name      = "lab-api pod not ready"
    condition = "C"
    # The condition must hold this long before the alert fires: the issue's 2 minutes.
    # Rolling updates (a new pod is not-ready for its startup delay, ~5 s) stay silent.
    for = "2m"

    # No series at all means kube-state-metrics or Alloy is down: that is not "a pod is
    # not ready", so it doesn't page through this rule.
    no_data_state  = "OK"
    exec_err_state = "Error"

    labels = {
      severity = "warning"
      cluster  = "k3s-gitops-lab"
    }
    annotations = {
      summary     = "lab-api pod {{ $labels.namespace }}/{{ $labels.pod }} not ready for 2 minutes"
      description = "kube_pod_status_ready{condition=\"false\"} = 1. The pod is out of the Service's endpoints. Check: kubectl -n {{ $labels.namespace }} describe pod {{ $labels.pod }}"
    }

    # Routes straight to the contact point (simplified routing): the stack's own
    # notification policy tree stays untouched.
    notification_settings {
      contact_point   = grafana_contact_point.email.name
      group_by        = ["alertname", "namespace", "pod"]
      group_wait      = "10s"
      repeat_interval = "4h"
    }

    data {
      ref_id         = "A"
      datasource_uid = var.prometheus_datasource_uid
      relative_time_range {
        from = 300
        to   = 0
      }
      model = jsonencode({
        refId   = "A"
        instant = true
        expr    = "max by (namespace, pod) (kube_pod_status_ready{cluster=\"k3s-gitops-lab\", namespace=~\"push|gitops\", condition=\"false\"})"
      })
    }

    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 0
        to   = 0
      }
      model = jsonencode({
        refId      = "C"
        type       = "threshold"
        expression = "A"
        conditions = [{ evaluator = { type = "gt", params = [0] } }]
      })
    }
  }
}
