import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";
import type { PlanConfig } from "@workerless/types";

export interface CreateWorkloadRbacCommandArgs {
  readonly provider: kubernetes.Provider;
  readonly namespace: kubernetes.core.v1.Namespace;
  readonly appId: string;
  readonly tenantId: string;
  readonly planKey: string;
  readonly plan: PlanConfig;
}

export class CreateWorkloadRbacCommand extends pulumi.ComponentResource {
  public readonly serviceAccount: kubernetes.core.v1.ServiceAccount;

  constructor(
    name: string,
    args: CreateWorkloadRbacCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:workload:CreateWorkloadRbacCommand", name, {}, opts);

    const ns = args.namespace.metadata.name;
    const defaultOpts: pulumi.ResourceOptions = {
      parent: this,
      provider: args.provider,
      dependsOn: [args.namespace],
    };

    this.serviceAccount = new kubernetes.core.v1.ServiceAccount(
      `${name}-sa`,
      {
        metadata: {
          name: args.appId,
          namespace: ns,
          labels: {
            "workerless.io/tenant": args.tenantId,
            "workerless.io/app": args.appId,
          },
        },
        automountServiceAccountToken: false,
      },
      defaultOpts,
    );

    new kubernetes.core.v1.LimitRange(
      `${name}-limits`,
      {
        metadata: {
          name: "worker-limits",
          namespace: ns,
          labels: {
            "workerless.io/plan": args.planKey,
          },
        },
        spec: {
          limits: [
            {
              type: "Container",
              default: {
                cpu: args.plan.container.defaultCpu,
                memory: args.plan.container.defaultMemory,
              },
              defaultRequest: {
                cpu: args.plan.container.defaultRequestCpu,
                memory: args.plan.container.defaultRequestMemory,
              },
              max: {
                cpu: args.plan.container.maxCpu,
                memory: args.plan.container.maxMemory,
              },
            },
          ],
        },
      },
      defaultOpts,
    );

    new kubernetes.core.v1.ResourceQuota(
      `${name}-quota`,
      {
        metadata: {
          name: "worker-quota",
          namespace: ns,
          labels: {
            "workerless.io/plan": args.planKey,
          },
        },
        spec: {
          hard: {
            "requests.cpu": args.plan.quota.requestsCpu,
            "requests.memory": args.plan.quota.requestsMemory,
            "limits.cpu": args.plan.quota.limitsCpu,
            "limits.memory": args.plan.quota.limitsMemory,
            pods: args.plan.quota.pods,
          },
        },
      },
      defaultOpts,
    );

    this.registerOutputs({});
  }
}
