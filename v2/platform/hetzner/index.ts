import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";
import { CorePlatformService } from "@workerless/core-platform";
import { WorkloadService } from "@workerless/workload";
import type { PlanConfig, WorkloadConfig } from "@workerless/types";

const config = new pulumi.Config();

const clusterStackRef =
  config.get("clusterStackRef") ??
  "organization/workerless-envs-hetzner/hetzner";

const clusterStack = new pulumi.StackReference("cluster-stack", {
  name: clusterStackRef,
});

const kubeCa = clusterStack.getOutput("kubeCa") as pulumi.Output<string>;
const kubeconfig = clusterStack.getOutput(
  "kubeconfig",
) as pulumi.Output<string>;

const provider = new kubernetes.Provider("k8s-hetzner", {
  kubeconfig,
});

const hcloudToken = config.requireSecret("hcloudToken");

new kubernetes.core.v1.Secret(
  "hcloud-csi-token",
  {
    metadata: {
      name: "hcloud",
      namespace: "kube-system",
    },
    stringData: {
      token: hcloudToken,
    },
  },
  { provider },
);

const csiRelease = new kubernetes.helm.v3.Release(
  "hcloud-csi",
  {
    name: "hcloud-csi",
    chart: "hcloud-csi",
    version: "2.10.0",
    namespace: "kube-system",
    repositoryOpts: {
      repo: "https://charts.hetzner.cloud",
    },
    values: {
      storageClasses: [
        {
          name: "hcloud-volumes",
          defaultStorageClass: true,
          reclaimPolicy: "Retain",
        },
      ],
    },
  },
  { provider },
);

const plans = config.requireObject<Record<string, PlanConfig>>("plans");
const workloads = config.requireObject<Record<string, WorkloadConfig>>("workloads");

const platform = new CorePlatformService(
  "core-platform",
  {
    provider,
    storageClassName: "hcloud-volumes",
    clusterPodCidr: "10.42.0.0/16",
    clusterServiceCidr: "10.43.0.0/16",
  },
  { dependsOn: [provider, csiRelease] },
);

Object.entries(workloads).forEach(([appId, workloadConfig]) => {
  const plan = plans[workloadConfig.planKey];
  if (plan === undefined) {
    throw new Error(
      `Plan "${workloadConfig.planKey}" not found for workload "${appId}"`,
    );
  }

  new WorkloadService(
    `workload-${appId}`,
    {
      provider,
      appId,
      config: workloadConfig,
      plan,
      esoRelease: platform.esoRelease,
      kedaRelease: platform.kedaRelease,
    },
    { dependsOn: [platform] },
  );
});

export const paasAdminToken = platform.paasAdminToken;
export const paasAdminTokenBase64 = platform.paasAdminTokenBase64;
export const clusterCa = kubeCa;
