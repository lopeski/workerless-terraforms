import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";

export interface CreateNamespacesCommandArgs {
  readonly provider: kubernetes.Provider;
}

export interface PlatformNamespaces {
  readonly externalSecrets: kubernetes.core.v1.Namespace;
  readonly keda: kubernetes.core.v1.Namespace;
  readonly monitoring: kubernetes.core.v1.Namespace;
  readonly kyverno: kubernetes.core.v1.Namespace;
}

export class CreateNamespacesCommand extends pulumi.ComponentResource {
  public readonly namespaces: PlatformNamespaces;

  constructor(
    name: string,
    args: CreateNamespacesCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:platform:CreateNamespacesCommand", name, {}, opts);

    const defaultOpts: pulumi.ResourceOptions = {
      parent: this,
      provider: args.provider,
    };

    const makeNamespace = (
      resourceName: string,
      namespaceName: string,
      psLevel: "baseline" | "privileged",
    ): kubernetes.core.v1.Namespace =>
      new kubernetes.core.v1.Namespace(
        `${name}-ns-${resourceName}`,
        {
          metadata: {
            name: namespaceName,
            labels: {
              "pod-security.kubernetes.io/enforce": psLevel,
              "pod-security.kubernetes.io/warn": psLevel,
              "app.kubernetes.io/managed-by": "pulumi",
            },
          },
        },
        defaultOpts,
      );

    this.namespaces = {
      externalSecrets: makeNamespace("eso", "external-secrets", "baseline"),
      keda: makeNamespace("keda", "keda", "baseline"),
      monitoring: makeNamespace("monitoring", "monitoring", "privileged"),
      kyverno: makeNamespace("kyverno", "kyverno", "privileged"),
    };

    this.registerOutputs({});
  }
}
