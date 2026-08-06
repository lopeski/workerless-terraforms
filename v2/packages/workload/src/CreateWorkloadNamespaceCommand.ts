import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";

export interface CreateWorkloadNamespaceCommandArgs {
  readonly provider: kubernetes.Provider;
  readonly namespaceName: string;
  readonly tenantId: string;
  readonly appId: string;
  readonly planKey: string;
}

export class CreateWorkloadNamespaceCommand extends pulumi.ComponentResource {
  public readonly namespace: kubernetes.core.v1.Namespace;

  constructor(
    name: string,
    args: CreateWorkloadNamespaceCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:workload:CreateWorkloadNamespaceCommand", name, {}, opts);

    if (args.namespaceName.length > 63) {
      throw new Error(
        `Namespace name "${args.namespaceName}" exceeds 63 character DNS label limit`,
      );
    }

    this.namespace = new kubernetes.core.v1.Namespace(
      `${name}-ns`,
      {
        metadata: {
          name: args.namespaceName,
          labels: {
            "pod-security.kubernetes.io/enforce": "baseline",
            "pod-security.kubernetes.io/warn": "baseline",
            "app.kubernetes.io/name": args.appId,
            "app.kubernetes.io/managed-by": "pulumi",
            "workerless.io/tenant": args.tenantId,
            "workerless.io/app": args.appId,
            "workerless.io/plan": args.planKey,
          },
        },
      },
      { parent: this, provider: args.provider },
    );

    this.registerOutputs({});
  }
}
