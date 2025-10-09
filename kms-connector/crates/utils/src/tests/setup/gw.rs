use crate::{
    config::KmsWallet,
    conn::WalletGatewayProvider,
    provider::{FillersWithoutNonceManagement, NonceManagedProvider},
    tests::setup::{ROOT_CARGO_TOML, pick_free_port},
};
use alloy::{
    primitives::{Address, ChainId, address},
    providers::{ProviderBuilder, WsConnect},
};
use fhevm_gateway_bindings::{
    decryption::Decryption::{self, DecryptionInstance},
    kms_generation::KMSGeneration::{self, KMSGenerationInstance},
};
use std::{str::from_utf8, sync::LazyLock, time::Duration};
use testcontainers::{
    ContainerAsync, GenericImage, ImageExt,
    core::{WaitFor, client::docker_client_instance},
    runners::AsyncRunner,
};
use tracing::{debug, info};

pub const DECRYPTION_MOCK_ADDRESS: Address = address!("0x9FA799F95A72258c0415DFEdd8Cf76D2613c750f");
pub const GATEWAY_CONFIG_MOCK_ADDRESS: Address =
    address!("0xE61cff9C581c7c91AEF682c2C10e8632864339ab");
pub const KMS_GENERATION_MOCK_ADDRESS: Address =
    address!("0x286f5339934279C74df10123bDbeEF3CaE932c22");

pub const TEST_MNEMONIC: &str =
    "coyote sketch defense hover finger envelope celery urge panther venue verb cheese";

pub static CHAIN_ID: LazyLock<u32> = LazyLock::new(rand::random::<u32>);

pub const DEPLOYER_PRIVATE_KEY: &str =
    "0xe746bc71f6bee141a954e6a49bc9384d334e393a7ea1e70b50241cb2e78e9e4c";

const ANVIL_PORT: u16 = 8545;

pub struct GatewayInstance {
    pub provider: WalletGatewayProvider,
    pub decryption_contract: DecryptionInstance<WalletGatewayProvider>,
    pub kms_generation_contract: KMSGenerationInstance<WalletGatewayProvider>,
    pub anvil: ContainerAsync<GenericImage>,
    pub anvil_host_port: u16,
    pub block_time: u64,
}

impl GatewayInstance {
    pub fn new(
        anvil: ContainerAsync<GenericImage>,
        anvil_host_port: u16,
        provider: WalletGatewayProvider,
        block_time: u64,
    ) -> Self {
        let decryption_contract = Decryption::new(DECRYPTION_MOCK_ADDRESS, provider.clone());
        let kms_generation_contract =
            KMSGeneration::new(KMS_GENERATION_MOCK_ADDRESS, provider.clone());

        GatewayInstance {
            provider,
            decryption_contract,
            kms_generation_contract,
            anvil,
            anvil_host_port,
            block_time,
        }
    }

    pub async fn setup() -> anyhow::Result<Self> {
        let block_time = 1;
        let anvil_host_port = pick_free_port();
        let anvil: ContainerAsync<GenericImage> =
            setup_anvil_gateway(anvil_host_port, block_time).await?;
        let wallet = KmsWallet::from_private_key_str(
            DEPLOYER_PRIVATE_KEY,
            Some(ChainId::from(*CHAIN_ID as u64)),
        )?;
        let wallet_addr = wallet.address();

        let inner_provider = ProviderBuilder::new()
            .disable_recommended_fillers()
            .with_chain_id(*CHAIN_ID as u64)
            .filler(FillersWithoutNonceManagement::default())
            .wallet(wallet)
            .connect_ws(WsConnect::new(Self::anvil_ws_endpoint_impl(
                anvil_host_port,
            )))
            .await?;
        let provider = NonceManagedProvider::new(inner_provider, wallet_addr);

        Ok(GatewayInstance::new(
            anvil,
            anvil_host_port,
            provider,
            block_time,
        ))
    }

    pub fn anvil_block_time(&self) -> Duration {
        Duration::from_secs(self.block_time)
    }

    fn anvil_ws_endpoint_impl(anvil_host_port: u16) -> String {
        format!("ws://localhost:{anvil_host_port}")
    }

    pub fn anvil_ws_endpoint(&self) -> String {
        Self::anvil_ws_endpoint_impl(self.anvil_host_port)
    }
}

pub async fn setup_anvil_gateway(
    host_port: u16,
    block_time: u64,
) -> anyhow::Result<ContainerAsync<GenericImage>> {
    info!("Starting Anvil...");
    let anvil = GenericImage::new("ghcr.io/foundry-rs/foundry", "v1.3.5")
        .with_wait_for(WaitFor::message_on_stdout("Listening"))
        .with_entrypoint("anvil")
        .with_cmd([
            "--host",
            "0.0.0.0",
            "--port",
            ANVIL_PORT.to_string().as_str(),
            "--chain-id",
            CHAIN_ID.to_string().as_str(),
            "--mnemonic",
            TEST_MNEMONIC,
            "--block-time",
            &format!("{block_time}"),
        ])
        .with_mapped_port(host_port, ANVIL_PORT.into())
        .start()
        .await?;

    let docker = docker_client_instance().await?;
    let inspect = docker.inspect_container(anvil.id(), None).await?;
    let networks = inspect.network_settings.unwrap().networks.unwrap();
    let endpoint_settings = networks.values().next().unwrap();
    let anvil_internal_ip = endpoint_settings.ip_address.clone().unwrap();

    info!("Deploying Gateway mock contracts...");
    let version = ROOT_CARGO_TOML.get_gateway_bindings_version();
    let deploy_mock_container =
        GenericImage::new("ghcr.io/zama-ai/fhevm/gateway-contracts", &version)
            .with_wait_for(WaitFor::message_on_stdout("Mock contract deployment done!"))
            .with_env_var("HARDHAT_NETWORK", "staging")
            .with_env_var(
                "RPC_URL",
                format!("http://{anvil_internal_ip}:{ANVIL_PORT}"),
            )
            .with_env_var("CHAIN_ID_GATEWAY", format!("{}", *CHAIN_ID))
            .with_env_var("MNEMONIC", TEST_MNEMONIC)
            .with_env_var(
                "DEPLOYER_ADDRESS",
                "0xCf28E90D4A6dB23c34E1881aEF5fd9fF2e478634",
            ) // accounts[1]
            .with_env_var("DEPLOYER_PRIVATE_KEY", DEPLOYER_PRIVATE_KEY) // accounts[1]
            .with_env_var(
                "PAUSER_ADDRESS",
                "0xfCefe53c7012a075b8a711df391100d9c431c468",
            )
            .with_cmd(["npx hardhat task:deployGatewayMockContracts"])
            .start()
            .await?;

    let stdout = deploy_mock_container.stdout_to_vec().await;
    let stderr = deploy_mock_container.stderr_to_vec().await;
    if let Ok(Ok(stdout)) = stdout.as_deref().map(from_utf8) {
        debug!("Stdout: {stdout}");
    }
    if let Ok(Ok(stderr)) = stderr.as_deref().map(from_utf8) {
        debug!("Stderr: {stderr}");
    }
    info!("Mock contract successfully deployed on Anvil!");

    Ok(anvil)
}
