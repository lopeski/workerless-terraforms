import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";

export interface CreatePaasAdminCommandArgs {
  readonly provider: kubernetes.Provider;
}

export class CreatePaasAdminCommand extends pulumi.ComponentResource {
  public readonly token: pulumi.Output<string>;
  public readonly tokenBase64: pulumi.Output<string>;

  constructor(
    name: string,
    args: CreatePaasAdminCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:platform:CreatePaasAdminCommand", name, {}, opts);

    const defaultOpts: pulumi.ResourceOptions = {
      parent: this,
      provider: args.provider,
    };

    const sa = new kubernetes.core.v1.ServiceAccount(
      `${name}-sa`,
      {
        metadata: {
          name: "paas-admin-sa",
          namespace: "kube-system",
        },
        automountServiceAccountToken: false,
      },
      defaultOpts,
    );

    const tokenSecret = new kubernetes.core.v1.Secret(
      `${name}-token`,
      {
        metadata: {
          name: "paas-admin-sa-token",
          namespace: "kube-system",
          annotations: {
            "kubernetes.io/service-account.name": sa.metadata.name,
          },
        },
        type: "kubernetes.io/service-account-token",
      },
      { ...defaultOpts, dependsOn: [sa] },
    );

    new kubernetes.rbac.v1.ClusterRoleBinding(
      `${name}-crb`,
      {
        metadata: { name: "paas-admin-sa-cluster-admin" },
        roleRef: {
          apiGroup: "rbac.authorization.k8s.io",
          kind: "ClusterRole",
          name: "cluster-admin",
        },
        subjects: [
          {
            kind: "ServiceAccount",
            name: "paas-admin-sa",
            namespace: "kube-system",
          },
        ],
      },
      { ...defaultOpts, dependsOn: [sa] },
    );

    const rawToken = tokenSecret.data.apply(
      (d) => d?.["token"] ?? "",
    );

    this.tokenBase64 = pulumi.secret(rawToken);
    this.token = pulumi.secret(
      rawToken.apply((t) => Buffer.from(t, "base64").toString("utf8")),
    );

    this.registerOutputs({
      token: this.token,
      tokenBase64: this.tokenBase64,
    });
  }
}
