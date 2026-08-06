import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";
import type {
  ComponentResourceConfig,
  MonitoringStorageConfig,
} from "@workerless/types";

export interface InstallMonitoringCommandArgs {
  readonly provider: kubernetes.Provider;
  readonly namespace: kubernetes.core.v1.Namespace;
  readonly storage: MonitoringStorageConfig;
  readonly prometheusResources?: ComponentResourceConfig;
  readonly alertmanagerResources?: ComponentResourceConfig;
  readonly grafanaResources?: ComponentResourceConfig;
}

const DEFAULT_PROMETHEUS_RESOURCES: ComponentResourceConfig = {
  requests: { cpu: "200m", memory: "512Mi" },
  limits: { cpu: "1000m", memory: "1Gi" },
};

const DEFAULT_ALERTMANAGER_RESOURCES: ComponentResourceConfig = {
  requests: { cpu: "50m", memory: "64Mi" },
  limits: { cpu: "200m", memory: "256Mi" },
};

const DEFAULT_GRAFANA_RESOURCES: ComponentResourceConfig = {
  requests: { cpu: "50m", memory: "128Mi" },
  limits: { cpu: "200m", memory: "256Mi" },
};

const DEFAULT_OPERATOR_RESOURCES: ComponentResourceConfig = {
  requests: { cpu: "100m", memory: "128Mi" },
  limits: { cpu: "500m", memory: "256Mi" },
};

export class InstallMonitoringCommand extends pulumi.ComponentResource {
  public readonly release: kubernetes.helm.v3.Release;

  constructor(
    name: string,
    args: InstallMonitoringCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:platform:InstallMonitoringCommand", name, {}, opts);

    const prometheusRes = args.prometheusResources ?? DEFAULT_PROMETHEUS_RESOURCES;
    const alertmanagerRes = args.alertmanagerResources ?? DEFAULT_ALERTMANAGER_RESOURCES;
    const grafanaRes = args.grafanaResources ?? DEFAULT_GRAFANA_RESOURCES;

    const prometheusSpec: Record<string, unknown> = {
      replicas: 2,
      retention: args.storage.prometheusRetention,
      scrapeInterval: "30s",
      evaluationInterval: args.storage.prometheusEvaluationInterval ?? "30s",
      resources: prometheusRes,
      storageSpec: {
        volumeClaimTemplate: {
          spec: {
            storageClassName: args.storage.storageClassName,
            accessModes: ["ReadWriteOnce"],
            resources: {
              requests: { storage: args.storage.prometheusSize },
            },
          },
        },
      },
      podDisruptionBudget: { enabled: true, minAvailable: 1 },
      affinity: {
        podAntiAffinity: {
          preferredDuringSchedulingIgnoredDuringExecution: [
            {
              weight: 100,
              podAffinityTerm: {
                labelSelector: {
                  matchLabels: { "app.kubernetes.io/name": "prometheus" },
                },
                topologyKey: "kubernetes.io/hostname",
              },
            },
          ],
        },
      },
    };

    if (args.storage.prometheusRetentionSize !== undefined) {
      prometheusSpec["retentionSize"] = args.storage.prometheusRetentionSize;
    }

    this.release = new kubernetes.helm.v3.Release(
      `${name}-monitoring`,
      {
        name: "kube-prometheus-stack",
        chart: "kube-prometheus-stack",
        version: "61.9.0",
        namespace: "monitoring",
        repositoryOpts: {
          repo: "https://prometheus-community.github.io/helm-charts",
        },
        values: {
          prometheusOperator: {
            resources: DEFAULT_OPERATOR_RESOURCES,
            affinity: {
              podAntiAffinity: {
                preferredDuringSchedulingIgnoredDuringExecution: [
                  {
                    weight: 100,
                    podAffinityTerm: {
                      labelSelector: {
                        matchLabels: {
                          "app.kubernetes.io/name": "prometheus-operator",
                        },
                      },
                      topologyKey: "kubernetes.io/hostname",
                    },
                  },
                ],
              },
            },
          },
          kubelet: {
            enabled: true,
            serviceMonitor: {
              cAdvisor: true,
            },
          },
          prometheus: {
            prometheusSpec,
          },
          alertmanager: {
            alertmanagerSpec: {
              replicas: 2,
              resources: alertmanagerRes,
              podDisruptionBudget: { minAvailable: 1 },
              storage: {
                volumeClaimTemplate: {
                  spec: {
                    storageClassName: args.storage.storageClassName,
                    accessModes: ["ReadWriteOnce"],
                    resources: {
                      requests: { storage: args.storage.alertmanagerSize },
                    },
                  },
                },
              },
            },
          },
          grafana: {
            replicas: 1,
            resources: grafanaRes,
            persistence: {
              enabled: true,
              storageClassName: args.storage.storageClassName,
              size: args.storage.grafanaSize,
              accessModes: ["ReadWriteOnce"],
            },
          },
          nodeExporter: { enabled: true },
          kubeStateMetrics: { enabled: true },
        },
      },
      {
        parent: this,
        provider: args.provider,
        dependsOn: [args.namespace],
      },
    );

    this.registerOutputs({});
  }
}
