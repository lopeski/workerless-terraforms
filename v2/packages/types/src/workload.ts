export type NetworkProtocol = "TCP" | "UDP" | "SCTP";

export interface EgressPort {
  readonly port: number;
  readonly protocol?: NetworkProtocol;
}

export interface EgressRule {
  readonly cidr: string;
  readonly ports: readonly EgressPort[];
}

export interface ExternalSecretRef {
  readonly name: string;
  readonly secretStoreName: string;
  readonly secretStoreKind: "SecretStore" | "ClusterSecretStore";
}

export interface KedaTriggerMetadata {
  readonly [key: string]: string;
}

export interface KedaTrigger {
  readonly type: string;
  readonly metadata: KedaTriggerMetadata;
  readonly authenticationRef?: {
    readonly name: string;
    readonly kind?: "TriggerAuthentication" | "ClusterTriggerAuthentication";
  };
}

export interface WorkloadConfig {
  readonly tenantId: string;
  readonly planKey: string;
  readonly workerImage: string;
  readonly minReplicas?: number;
  readonly externalSecretRef: ExternalSecretRef;
  readonly eventSourceEgressRules: readonly EgressRule[];
  readonly kedaTriggers: readonly KedaTrigger[];
  readonly kedaAuthenticationManifests?: readonly Record<string, unknown>[];
  readonly nodeSelector?: Readonly<Record<string, string>>;
}
