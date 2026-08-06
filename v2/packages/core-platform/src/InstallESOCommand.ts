import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";
import type { ComponentResourceConfig } from "@workerless/types";

export interface InstallESOCommandArgs {
  readonly provider: kubernetes.Provider;
  readonly namespace: kubernetes.core.v1.Namespace;
  readonly resources?: ComponentResourceConfig;
}

const DEFAULT_RESOURCES: ComponentResourceConfig = {
  requests: { cpu: "50m", memory: "128Mi" },
  limits: { cpu: "200m", memory: "256Mi" },
};

export class InstallESOCommand extends pulumi.ComponentResource {
  public readonly release: kubernetes.helm.v3.Release;

  constructor(
    name: string,
    args: InstallESOCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:platform:InstallESOCommand", name, {}, opts);

    const resources = args.resources ?? DEFAULT_RESOURCES;

    this.release = new kubernetes.helm.v3.Release(
      `${name}-eso`,
      {
        name: "external-secrets",
        chart: "external-secrets",
        version: "2.5.0",
        namespace: "external-secrets",
        repositoryOpts: {
          repo: "https://charts.external-secrets.io",
        },
        values: {
          installCRDs: true,
          replicaCount: 2,
          resources: {
            requests: resources.requests,
            limits: resources.limits,
          },
          webhook: {
            replicaCount: 2,
            resources: {
              requests: resources.requests,
              limits: resources.limits,
            },
          },
          certController: {
            replicaCount: 2,
            resources: {
              requests: resources.requests,
              limits: resources.limits,
            },
          },
          podDisruptionBudget: {
            enabled: true,
            minAvailable: 1,
          },
          affinity: {
            podAntiAffinity: {
              preferredDuringSchedulingIgnoredDuringExecution: [
                {
                  weight: 100,
                  podAffinityTerm: {
                    labelSelector: {
                      matchLabels: {
                        "app.kubernetes.io/name": "external-secrets",
                      },
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
                matchLabels: { "app.kubernetes.io/name": "external-secrets" },
              },
            },
          ],
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
