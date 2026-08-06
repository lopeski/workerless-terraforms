import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";
import type { ComponentResourceConfig } from "@workerless/types";

export interface InstallKyvernoCommandArgs {
  readonly provider: kubernetes.Provider;
  readonly namespace: kubernetes.core.v1.Namespace;
  readonly resources?: ComponentResourceConfig;
}

const DEFAULT_RESOURCES: ComponentResourceConfig = {
  requests: { cpu: "100m", memory: "256Mi" },
  limits: { cpu: "500m", memory: "512Mi" },
};

const PSS_NAMESPACES_EXCLUDED = [
  "kube-system",
  "kube-public",
  "kube-node-lease",
  "kyverno",
  "monitoring",
  "external-secrets",
];

const PSS_BASELINE_POLICY = {
  apiVersion: "kyverno.io/v1",
  kind: "ClusterPolicy",
  metadata: {
    name: "pss-baseline",
    annotations: {
      "policies.kyverno.io/title": "Enforce PSS Baseline",
      "policies.kyverno.io/category": "Pod Security Standards",
    },
  },
  spec: {
    failureAction: "Enforce",
    background: true,
    rules: [
      {
        name: "baseline",
        match: {
          any: [{ resources: { kinds: ["Pod"] } }],
        },
        exclude: {
          any: [
            {
              resources: { namespaces: PSS_NAMESPACES_EXCLUDED },
            },
          ],
        },
        validate: {
          podSecurity: {
            level: "baseline",
            version: "latest",
          },
        },
      },
    ],
  },
};

export class InstallKyvernoCommand extends pulumi.ComponentResource {
  public readonly release: kubernetes.helm.v3.Release;
  public readonly policy: kubernetes.apiextensions.CustomResource;

  constructor(
    name: string,
    args: InstallKyvernoCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:platform:InstallKyvernoCommand", name, {}, opts);

    const resources = args.resources ?? DEFAULT_RESOURCES;

    this.release = new kubernetes.helm.v3.Release(
      `${name}-kyverno`,
      {
        name: "kyverno",
        chart: "kyverno",
        version: "3.3.4",
        namespace: "kyverno",
        repositoryOpts: {
          repo: "https://kyverno.github.io/kyverno/",
        },
        values: {
          admissionController: {
            replicas: 2,
            resources: {
              requests: resources.requests,
              limits: resources.limits,
            },
            podDisruptionBudget: { minAvailable: 1 },
          },
          backgroundController: {
            replicas: 2,
            resources: {
              requests: resources.requests,
              limits: resources.limits,
            },
            podDisruptionBudget: { minAvailable: 1 },
          },
          cleanupController: {
            replicas: 2,
            resources: {
              requests: resources.requests,
              limits: resources.limits,
            },
            podDisruptionBudget: { minAvailable: 1 },
          },
          reportsController: {
            replicas: 2,
            resources: {
              requests: resources.requests,
              limits: resources.limits,
            },
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

    this.policy = new kubernetes.apiextensions.CustomResource(
      `${name}-pss-policy`,
      PSS_BASELINE_POLICY,
      {
        parent: this,
        provider: args.provider,
        dependsOn: [this.release],
      },
    );

    this.registerOutputs({});
  }
}
