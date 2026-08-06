import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";

export interface WorkloadDevSecretConfig {
  readonly secretName: string;
  readonly data: Readonly<Record<string, string>>;
}

export interface DevSecretsBackendServiceArgs {
  readonly provider: kubernetes.Provider;
  readonly workloadSecrets: readonly WorkloadDevSecretConfig[];
  readonly esoRelease: kubernetes.helm.v3.Release;
}

export class DevSecretsBackendService extends pulumi.ComponentResource {
  public readonly clusterSecretStoreName: pulumi.Output<string>;

  constructor(
    name: string,
    args: DevSecretsBackendServiceArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:devSecrets:DevSecretsBackendService", name, {}, opts);

    const defaultOpts: pulumi.ResourceOptions = {
      parent: this,
      provider: args.provider,
    };

    const ns = new kubernetes.core.v1.Namespace(
      `${name}-ns`,
      {
        metadata: {
          name: "dev-secrets",
          labels: {
            "app.kubernetes.io/managed-by": "pulumi",
            "workerless.io/env": "development",
          },
        },
      },
      defaultOpts,
    );

    const sa = new kubernetes.core.v1.ServiceAccount(
      `${name}-sa`,
      {
        metadata: {
          name: "dev-secret-reader",
          namespace: "dev-secrets",
        },
      },
      { ...defaultOpts, dependsOn: [ns] },
    );

    const role = new kubernetes.rbac.v1.Role(
      `${name}-role`,
      {
        metadata: {
          name: "dev-secret-reader",
          namespace: "dev-secrets",
        },
        rules: [
          {
            apiGroups: [""],
            resources: ["secrets"],
            verbs: ["get", "list", "watch"],
          },
        ],
      },
      { ...defaultOpts, dependsOn: [ns] },
    );

    new kubernetes.rbac.v1.RoleBinding(
      `${name}-rolebinding`,
      {
        metadata: {
          name: "dev-secret-reader",
          namespace: "dev-secrets",
        },
        roleRef: {
          apiGroup: "rbac.authorization.k8s.io",
          kind: "Role",
          name: role.metadata.name,
        },
        subjects: [
          {
            kind: "ServiceAccount",
            name: sa.metadata.name,
            namespace: "dev-secrets",
          },
        ],
      },
      { ...defaultOpts, dependsOn: [ns, role, sa] },
    );

    args.workloadSecrets.forEach((workloadSecret) => {
      new kubernetes.core.v1.Secret(
        `${name}-secret-${workloadSecret.secretName}`,
        {
          metadata: {
            name: workloadSecret.secretName,
            namespace: "dev-secrets",
            labels: {
              "workerless.io/env": "development",
            },
          },
          stringData: workloadSecret.data,
        },
        { ...defaultOpts, dependsOn: [ns] },
      );
    });

    const clusterStore = new kubernetes.apiextensions.CustomResource(
      `${name}-cluster-store`,
      {
        apiVersion: "external-secrets.io/v1beta1",
        kind: "ClusterSecretStore",
        metadata: {
          name: "dev-secrets",
        },
        spec: {
          provider: {
            kubernetes: {
              remoteNamespace: "dev-secrets",
              server: {
                caProvider: {
                  type: "ConfigMap",
                  name: "kube-root-ca.crt",
                  key: "ca.crt",
                  namespace: "dev-secrets",
                },
              },
              auth: {
                serviceAccount: {
                  name: sa.metadata.name,
                  namespace: "dev-secrets",
                },
              },
            },
          },
        },
      },
      {
        ...defaultOpts,
        dependsOn: [ns, sa, args.esoRelease],
      },
    );

    this.clusterSecretStoreName = clusterStore.metadata.name;

    this.registerOutputs({ clusterSecretStoreName: this.clusterSecretStoreName });
  }
}
