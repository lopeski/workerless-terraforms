import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";
import type {
  EgressRule,
  MonitoringStorageConfig,
  PlatformResourceOverrides,
} from "@workerless/types";
import { CreateNamespacesCommand } from "./CreateNamespacesCommand";
import { InstallESOCommand } from "./InstallESOCommand";
import type { InstallESOCommandArgs } from "./InstallESOCommand";
import { InstallKEDACommand } from "./InstallKEDACommand";
import type { InstallKEDACommandArgs } from "./InstallKEDACommand";
import { InstallKyvernoCommand } from "./InstallKyvernoCommand";
import type { InstallKyvernoCommandArgs } from "./InstallKyvernoCommand";
import { PatchCoreDNSCommand } from "./PatchCoreDNSCommand";
import { InstallMonitoringCommand } from "./InstallMonitoringCommand";
import type { InstallMonitoringCommandArgs } from "./InstallMonitoringCommand";
import { CreateNetworkPoliciesCommand } from "./CreateNetworkPoliciesCommand";
import { CreatePaasAdminCommand } from "./CreatePaasAdminCommand";

export interface CorePlatformServiceArgs {
  readonly provider: kubernetes.Provider;
  readonly clusterPodCidr?: string;
  readonly clusterServiceCidr?: string;
  readonly storageClassName?: string;
  readonly eventSourceEgressRules?: readonly EgressRule[];
  readonly platformResources?: PlatformResourceOverrides;
  readonly monitoringStorage?: Partial<MonitoringStorageConfig>;
}

const DEFAULT_SERVICE_CIDR = "10.43.0.0/16";

const DEFAULT_MONITORING_STORAGE: MonitoringStorageConfig = {
  prometheusSize: "50Gi",
  prometheusRetention: "15d",
  prometheusRetentionSize: "40GiB",
  prometheusEvaluationInterval: "30s",
  alertmanagerSize: "5Gi",
  grafanaSize: "10Gi",
  storageClassName: "local-path",
};

export class CorePlatformService extends pulumi.ComponentResource {
  public readonly paasAdminToken: pulumi.Output<string>;
  public readonly paasAdminTokenBase64: pulumi.Output<string>;
  public readonly esoRelease: kubernetes.helm.v3.Release;
  public readonly kedaRelease: kubernetes.helm.v3.Release;

  constructor(
    name: string,
    args: CorePlatformServiceArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:platform:CorePlatformService", name, {}, opts);

    const serviceCidr = args.clusterServiceCidr ?? DEFAULT_SERVICE_CIDR;
    const storageClass = args.storageClassName ?? "local-path";
    const egressRules = args.eventSourceEgressRules ?? [];

    const storage: MonitoringStorageConfig = {
      ...DEFAULT_MONITORING_STORAGE,
      ...args.monitoringStorage,
      storageClassName: storageClass,
    };

    const namespaces = new CreateNamespacesCommand(
      `${name}-namespaces`,
      { provider: args.provider },
      { parent: this },
    );

    const esoArgs: InstallESOCommandArgs = {
      provider: args.provider,
      namespace: namespaces.namespaces.externalSecrets,
      ...(args.platformResources?.externalSecrets !== undefined
        ? { resources: args.platformResources.externalSecrets }
        : {}),
    };
    const eso = new InstallESOCommand(
      `${name}-eso`,
      esoArgs,
      { parent: this, dependsOn: [namespaces] },
    );

    const kedaArgs: InstallKEDACommandArgs = {
      provider: args.provider,
      namespace: namespaces.namespaces.keda,
      ...(args.platformResources?.keda !== undefined
        ? { resources: args.platformResources.keda }
        : {}),
    };
    const keda = new InstallKEDACommand(
      `${name}-keda`,
      kedaArgs,
      { parent: this, dependsOn: [namespaces] },
    );

    const kyvernoArgs: InstallKyvernoCommandArgs = {
      provider: args.provider,
      namespace: namespaces.namespaces.kyverno,
      ...(args.platformResources?.kyverno !== undefined
        ? { resources: args.platformResources.kyverno }
        : {}),
    };
    const kyverno = new InstallKyvernoCommand(
      `${name}-kyverno`,
      kyvernoArgs,
      { parent: this, dependsOn: [namespaces] },
    );

    new PatchCoreDNSCommand(
      `${name}-coredns`,
      { provider: args.provider },
      { parent: this },
    );

    const monitoringArgs: InstallMonitoringCommandArgs = {
      provider: args.provider,
      namespace: namespaces.namespaces.monitoring,
      storage,
      ...(args.platformResources?.prometheus !== undefined
        ? { prometheusResources: args.platformResources.prometheus }
        : {}),
      ...(args.platformResources?.alertmanager !== undefined
        ? { alertmanagerResources: args.platformResources.alertmanager }
        : {}),
      ...(args.platformResources?.grafana !== undefined
        ? { grafanaResources: args.platformResources.grafana }
        : {}),
    };
    new InstallMonitoringCommand(
      `${name}-monitoring`,
      monitoringArgs,
      { parent: this, dependsOn: [namespaces] },
    );

    new CreateNetworkPoliciesCommand(
      `${name}-netpolicies`,
      {
        provider: args.provider,
        kedaNamespace: namespaces.namespaces.keda,
        monitoringNamespace: namespaces.namespaces.monitoring,
        clusterServiceCidr: serviceCidr,
        eventSourceEgressRules: egressRules,
      },
      { parent: this, dependsOn: [namespaces] },
    );

    const paasAdmin = new CreatePaasAdminCommand(
      `${name}-paas-admin`,
      { provider: args.provider },
      { parent: this, dependsOn: [eso, keda, kyverno] },
    );

    this.esoRelease = eso.release;
    this.kedaRelease = keda.release;
    this.paasAdminToken = paasAdmin.token;
    this.paasAdminTokenBase64 = paasAdmin.tokenBase64;

    this.registerOutputs({
      paasAdminToken: this.paasAdminToken,
      paasAdminTokenBase64: this.paasAdminTokenBase64,
    });
  }
}
