import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";
import type { ExternalSecretRef } from "@workerless/types";

export interface CreateExternalSecretCommandArgs {
  readonly provider: kubernetes.Provider;
  readonly namespace: kubernetes.core.v1.Namespace;
  readonly appId: string;
  readonly externalSecretRef: ExternalSecretRef;
  readonly esoRelease: kubernetes.helm.v3.Release;
}

export class CreateExternalSecretCommand extends pulumi.ComponentResource {
  public readonly externalSecret: kubernetes.apiextensions.CustomResource;

  constructor(
    name: string,
    args: CreateExternalSecretCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:workload:CreateExternalSecretCommand", name, {}, opts);

    const ns = args.namespace.metadata.name;

    this.externalSecret = new kubernetes.apiextensions.CustomResource(
      `${name}-ext-secret`,
      {
        apiVersion: "external-secrets.io/v1beta1",
        kind: "ExternalSecret",
        metadata: {
          name: args.externalSecretRef.name,
          namespace: ns,
          labels: {
            "workerless.io/app": args.appId,
          },
        },
        spec: {
          refreshInterval: "1h",
          secretStoreRef: {
            kind: args.externalSecretRef.secretStoreKind,
            name: args.externalSecretRef.secretStoreName,
          },
          target: {
            name: args.externalSecretRef.name,
            creationPolicy: "Owner",
          },
          dataFrom: [
            {
              extract: {
                key: args.externalSecretRef.name,
              },
            },
          ],
        },
      },
      {
        parent: this,
        provider: args.provider,
        dependsOn: [args.namespace, args.esoRelease],
      },
    );

    this.registerOutputs({});
  }
}
