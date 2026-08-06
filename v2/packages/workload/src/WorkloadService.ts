import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";
import type { WorkloadConfig, PlanConfig } from "@workerless/types";
import { CreateWorkloadNamespaceCommand } from "./CreateWorkloadNamespaceCommand";
import { CreateWorkloadRbacCommand } from "./CreateWorkloadRbacCommand";
import { CreateExternalSecretCommand } from "./CreateExternalSecretCommand";
import { CreateWorkloadNetworkPoliciesCommand } from "./CreateNetworkPoliciesCommand";
import { CreateWorkerDeploymentCommand } from "./CreateWorkerDeploymentCommand";
import type { CreateWorkerDeploymentCommandArgs } from "./CreateWorkerDeploymentCommand";
import { CreateKedaScalerCommand } from "./CreateKedaScalerCommand";
import type { CreateKedaScalerCommandArgs } from "./CreateKedaScalerCommand";

export interface WorkloadServiceArgs {
  readonly provider: kubernetes.Provider;
  readonly appId: string;
  readonly config: WorkloadConfig;
  readonly plan: PlanConfig;
  readonly esoRelease: kubernetes.helm.v3.Release;
  readonly kedaRelease: kubernetes.helm.v3.Release;
}

export class WorkloadService extends pulumi.ComponentResource {
  public readonly namespaceName: pulumi.Output<string>;

  constructor(
    name: string,
    args: WorkloadServiceArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:workload:WorkloadService", name, {}, opts);

    const { appId, config, plan, provider } = args;
    const namespaceName = `wl-${config.tenantId}-${appId}`;

    const nsCommand = new CreateWorkloadNamespaceCommand(
      `${name}-ns`,
      {
        provider,
        namespaceName,
        tenantId: config.tenantId,
        appId,
        planKey: config.planKey,
      },
      { parent: this },
    );

    const rbac = new CreateWorkloadRbacCommand(
      `${name}-rbac`,
      {
        provider,
        namespace: nsCommand.namespace,
        appId,
        tenantId: config.tenantId,
        planKey: config.planKey,
        plan,
      },
      { parent: this, dependsOn: [nsCommand] },
    );

    const externalSecret = new CreateExternalSecretCommand(
      `${name}-ext-secret`,
      {
        provider,
        namespace: nsCommand.namespace,
        appId,
        externalSecretRef: config.externalSecretRef,
        esoRelease: args.esoRelease,
      },
      { parent: this, dependsOn: [nsCommand] },
    );

    new CreateWorkloadNetworkPoliciesCommand(
      `${name}-netpolicies`,
      {
        provider,
        namespace: nsCommand.namespace,
        eventSourceEgressRules: config.eventSourceEgressRules,
      },
      { parent: this, dependsOn: [nsCommand] },
    );

    const deployArgs: CreateWorkerDeploymentCommandArgs = {
      provider,
      namespace: nsCommand.namespace,
      serviceAccount: rbac.serviceAccount,
      appId,
      tenantId: config.tenantId,
      planKey: config.planKey,
      workerImage: config.workerImage,
      secretName: config.externalSecretRef.name,
      plan,
      ...(config.nodeSelector !== undefined
        ? { nodeSelector: config.nodeSelector }
        : {}),
    };
    const deployment = new CreateWorkerDeploymentCommand(
      `${name}-deploy`,
      deployArgs,
      { parent: this, dependsOn: [rbac, externalSecret] },
    );

    const scalerArgs: CreateKedaScalerCommandArgs = {
      provider,
      namespace: nsCommand.namespace,
      deployment: deployment.deployment,
      appId,
      minReplicas: config.minReplicas ?? 0,
      maxReplicas: plan.maxReplicas,
      triggers: config.kedaTriggers,
      kedaRelease: args.kedaRelease,
      ...(config.kedaAuthenticationManifests !== undefined
        ? { authenticationManifests: config.kedaAuthenticationManifests }
        : {}),
    };
    new CreateKedaScalerCommand(
      `${name}-scaler`,
      scalerArgs,
      { parent: this, dependsOn: [deployment] },
    );

    this.namespaceName = nsCommand.namespace.metadata.name;

    this.registerOutputs({ namespaceName: this.namespaceName });
  }
}
