import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";
import type { PlanConfig } from "@workerless/types";

export interface CreateWorkerDeploymentCommandArgs {
  readonly provider: kubernetes.Provider;
  readonly namespace: kubernetes.core.v1.Namespace;
  readonly serviceAccount: kubernetes.core.v1.ServiceAccount;
  readonly appId: string;
  readonly tenantId: string;
  readonly planKey: string;
  readonly workerImage: string;
  readonly secretName: string;
  readonly plan: PlanConfig;
  readonly nodeSelector?: Readonly<Record<string, string>>;
}

export class CreateWorkerDeploymentCommand extends pulumi.ComponentResource {
  public readonly deployment: kubernetes.apps.v1.Deployment;

  constructor(
    name: string,
    args: CreateWorkerDeploymentCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:workload:CreateWorkerDeploymentCommand", name, {}, opts);

    const ns = args.namespace.metadata.name;

    const commonLabels = {
      "app.kubernetes.io/name": args.appId,
      "workerless.io/tenant": args.tenantId,
      "workerless.io/app": args.appId,
      "workerless.io/plan": args.planKey,
    };

    this.deployment = new kubernetes.apps.v1.Deployment(
      `${name}-deploy`,
      {
        metadata: {
          name: args.appId,
          namespace: ns,
          labels: commonLabels,
        },
        spec: {
          replicas: 1,
          selector: {
            matchLabels: {
              "app.kubernetes.io/name": args.appId,
              "workerless.io/app": args.appId,
            },
          },
          template: {
            metadata: {
              labels: commonLabels,
              annotations: {
                "kubectl.kubernetes.io/default-container": args.appId,
              },
            },
            spec: {
              serviceAccountName: args.appId,
              automountServiceAccountToken: false,
              securityContext: {
                runAsNonRoot: true,
                runAsUser: 1000,
                runAsGroup: 1000,
                fsGroup: 1000,
                seccompProfile: { type: "RuntimeDefault" },
              },
              nodeSelector:
                args.nodeSelector !== undefined
                  ? { ...args.nodeSelector }
                  : undefined,
              containers: [
                {
                  name: args.appId,
                  image: args.workerImage,
                  securityContext: {
                    allowPrivilegeEscalation: false,
                    readOnlyRootFilesystem: true,
                    capabilities: { drop: ["ALL"] },
                  },
                  resources: {
                    requests: {
                      cpu: args.plan.container.defaultRequestCpu,
                      memory: args.plan.container.defaultRequestMemory,
                    },
                    limits: {
                      cpu: args.plan.container.defaultCpu,
                      memory: args.plan.container.defaultMemory,
                    },
                  },
                  envFrom: [
                    {
                      secretRef: { name: args.secretName },
                    },
                  ],
                  volumeMounts: [
                    {
                      name: "tmp",
                      mountPath: "/tmp",
                    },
                  ],
                },
              ],
              volumes: [
                {
                  name: "tmp",
                  emptyDir: {},
                },
              ],
            },
          },
        },
      },
      {
        parent: this,
        provider: args.provider,
        dependsOn: [args.namespace, args.serviceAccount],
      },
    );

    this.registerOutputs({});
  }
}
