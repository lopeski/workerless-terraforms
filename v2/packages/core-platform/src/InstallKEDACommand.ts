import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";
import type { ComponentResourceConfig } from "@workerless/types";

export interface InstallKEDACommandArgs {
  readonly provider: kubernetes.Provider;
  readonly namespace: kubernetes.core.v1.Namespace;
  readonly resources?: ComponentResourceConfig;
}

const DEFAULT_RESOURCES: ComponentResourceConfig = {
  requests: { cpu: "100m", memory: "128Mi" },
  limits: { cpu: "500m", memory: "512Mi" },
};

export class InstallKEDACommand extends pulumi.ComponentResource {
  public readonly release: kubernetes.helm.v3.Release;

  constructor(
    name: string,
    args: InstallKEDACommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:platform:InstallKEDACommand", name, {}, opts);

    const resources = args.resources ?? DEFAULT_RESOURCES;

    this.release = new kubernetes.helm.v3.Release(
      `${name}-keda`,
      {
        name: "keda",
        chart: "keda",
        version: "2.19.0",
        namespace: "keda",
        repositoryOpts: {
          repo: "https://kedacore.github.io/charts",
        },
        values: {
          replicaCount: 2,
          resources: {
            operator: {
              requests: resources.requests,
              limits: resources.limits,
            },
            metricServer: {
              requests: resources.requests,
              limits: resources.limits,
            },
            webhooks: {
              requests: resources.requests,
              limits: resources.limits,
            },
          },
          podDisruptionBudget: {
            operator: { minAvailable: 1 },
            metricServer: { minAvailable: 1 },
          },
          affinity: {
            podAntiAffinity: {
              preferredDuringSchedulingIgnoredDuringExecution: [
                {
                  weight: 100,
                  podAffinityTerm: {
                    labelSelector: {
                      matchLabels: { app: "keda-operator" },
                    },
                    topologyKey: "kubernetes.io/hostname",
                  },
                },
              ],
            },
          },
          topologySpreadConstraints: [
            {
              maxSkew: 1,
              topologyKey: "kubernetes.io/hostname",
              whenUnsatisfiable: "ScheduleAnyway",
              labelSelector: {
                matchLabels: { app: "keda-operator" },
              },
            },
          ],
          webhooks: {
            podDisruptionBudget: { minAvailable: 1 },
          },
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
