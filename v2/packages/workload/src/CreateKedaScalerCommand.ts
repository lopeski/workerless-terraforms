import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";
import type { KedaTrigger } from "@workerless/types";

export interface CreateKedaScalerCommandArgs {
  readonly provider: kubernetes.Provider;
  readonly namespace: kubernetes.core.v1.Namespace;
  readonly deployment: kubernetes.apps.v1.Deployment;
  readonly appId: string;
  readonly minReplicas: number;
  readonly maxReplicas: number;
  readonly triggers: readonly KedaTrigger[];
  readonly authenticationManifests?: readonly Record<string, unknown>[];
  readonly kedaRelease: kubernetes.helm.v3.Release;
}

export class CreateKedaScalerCommand extends pulumi.ComponentResource {
  public readonly scaledObject: kubernetes.apiextensions.CustomResource;
  public readonly triggerAuthentications: readonly kubernetes.apiextensions.CustomResource[];

  constructor(
    name: string,
    args: CreateKedaScalerCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:workload:CreateKedaScalerCommand", name, {}, opts);

    const ns = args.namespace.metadata.name;
    const baseDeps = [args.namespace, args.kedaRelease];

    const auths: kubernetes.apiextensions.CustomResource[] = (
      args.authenticationManifests ?? []
    ).map((manifest, i) => {
      const isCluster =
        (manifest as Record<string, unknown>)["kind"] ===
        "ClusterTriggerAuthentication";
      const manifestWithNs = isCluster
        ? manifest
        : {
            ...manifest,
            metadata: {
              ...(manifest["metadata"] as Record<string, unknown>),
              namespace: ns,
            },
          };

      return new kubernetes.apiextensions.CustomResource(
        `${name}-auth-${i}`,
        manifestWithNs as kubernetes.apiextensions.CustomResourceArgs,
        {
          parent: this,
          provider: args.provider,
          dependsOn: baseDeps,
        },
      );
    });

    this.triggerAuthentications = auths;

    this.scaledObject = new kubernetes.apiextensions.CustomResource(
      `${name}-scaledobject`,
      {
        apiVersion: "keda.sh/v1alpha1",
        kind: "ScaledObject",
        metadata: {
          name: args.appId,
          namespace: ns,
          labels: {
            "workerless.io/app": args.appId,
          },
        },
        spec: {
          scaleTargetRef: {
            name: args.appId,
          },
          minReplicaCount: args.minReplicas,
          maxReplicaCount: args.maxReplicas,
          triggers: args.triggers.map((t) => ({
            type: t.type,
            metadata: t.metadata,
            ...(t.authenticationRef !== undefined
              ? { authenticationRef: t.authenticationRef }
              : {}),
          })),
        },
      },
      {
        parent: this,
        provider: args.provider,
        dependsOn: [...baseDeps, args.deployment, ...auths],
      },
    );

    this.registerOutputs({});
  }
}
