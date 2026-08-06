import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";
import { CorePlatformService } from "@workerless/core-platform";
import { WorkloadService } from "@workerless/workload";
import { DevSecretsBackendService } from "@workerless/dev-secrets";
import type { PlanConfig, WorkloadConfig } from "@workerless/types";

const config = new pulumi.Config();

const clusterStackRef =
  config.get("clusterStackRef") ?? "organization/workerless-envs-local/local";

const clusterStack = new pulumi.StackReference("cluster-stack", {
  name: clusterStackRef,
});

const provider = new kubernetes.Provider("k8s-local", {
  kubeconfig: clusterStack.getOutput("kubeconfigPath") as pulumi.Output<string>,
  context: clusterStack.getOutput("kubeContext") as pulumi.Output<string>,
});

const plans = config.requireObject<Record<string, PlanConfig>>("plans");
const workloads = config.requireObject<Record<string, WorkloadConfig>>("workloads");

const platform = new CorePlatformService(
  "core-platform",
  {
    provider,
    storageClassName: "local-path",
    clusterPodCidr: "10.42.0.0/16",
    clusterServiceCidr: "10.43.0.0/16",
  },
  { dependsOn: [provider] },
);

const devSecrets = new DevSecretsBackendService(
  "dev-secrets",
  {
    provider,
    esoRelease: platform.esoRelease,
    workloadSecrets: Object.entries(workloads).map(([appId, wl]) => ({
      secretName: wl.externalSecretRef.name,
      data: {
        PLACEHOLDER_KEY: "placeholder-value",
        APP_ID: appId,
        TENANT_ID: wl.tenantId,
      },
    })),
  },
  { dependsOn: [platform] },
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
    { dependsOn: [platform, devSecrets] },
  );
});

export const paasAdminToken = platform.paasAdminToken;
export const paasAdminTokenBase64 = platform.paasAdminTokenBase64;
