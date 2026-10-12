//! External overlay mounted beneath Sophia's normal lock-provider test owner.
//! Requires a prebuilt Kleis; no display, rendering or unlock claim.
use super::*;

fn advance(provider: &mut LockProvider, auth: &mut factotum::Fixture) -> Vec<LockFileServiceEvent> {
    auth.tick();
    provider.poll(Instant::now(), &mut auth.coordinator)
}

#[test]
fn kleis_authenticates_and_recovers_through_the_normal_lock_owner() {
    let executable = PathBuf::from(std::env::var_os("KLEIS_AUTH_PEER").unwrap());
    assert!(executable.is_absolute() && executable.is_file());
    let directory = Directory::new("kleis-auth");
    let transport = LockFileTransport::bind_for_supervised_uid(
        directory.0.join("endpoint"),
        rustix::process::geteuid().as_raw(),
        1,
        limits(),
    )
    .unwrap();
    let socket = transport.socket_path().to_owned();
    let launch = ProcessLaunchSpec::new(executable)
        .env(sophia_runtime::SOPHIA_LOCK_9P_SOCKET_ENV, &socket)
        .arg("--no-gpu")
        .arg("--blank")
        .process_group()
        .protection_domain(
            ProtectionDomainSpec::bubblewrap([ProtectionDomainRole::LockProvider])
                .unwrap()
                .path(ProtectionPath::read_only(socket.parent().unwrap()))
                .unwrap(),
        );
    let mut auth = factotum::Fixture::new();
    let wake = sophia_wake::Wake::new().unwrap();
    let mut provider = LockProvider::with_service(
        transport,
        launch,
        ShellGpuMode::Denied,
        None,
        locked(),
        Vec::new(),
        wake.notifier(),
        policy(),
        auth.coordinator.endpoint(),
    )
    .unwrap();
    let mut previous = None;
    for epoch in [1, 2] {
        let deadline = Instant::now() + Duration::from_secs(12);
        let mut connected = false;
        while !connected {
            assert!(
                Instant::now() < deadline,
                "Kleis must negotiate through the authenticated lock owner"
            );
            connected = advance(&mut provider, &mut auth).iter().any(|event|
                matches!(event, LockFileServiceEvent::Connected { connection_epoch, .. } if *connection_epoch == epoch));
        }
        let registration = provider.registration.unwrap();
        assert_ne!(Some(registration), previous);
        assert_eq!(auth.coordinator.phase(registration), Some(Phase::Active));
        let until = Instant::now() + Duration::from_millis(250);
        while Instant::now() < until {
            advance(&mut provider, &mut auth);
            assert!(
                provider
                    .supervisor
                    .as_ref()
                    .unwrap()
                    .exit_status()
                    .is_none(),
                "connected Kleis must remain alive until requested retirement"
            );
        }
        assert!(provider.authorized);
        println!("kleis_authenticated epoch={epoch} status=connected");
        provider.replace_process(Instant::now(), &mut auth.coordinator);
        let deadline = Instant::now() + Duration::from_secs(5);
        while auth.coordinator.phase(registration).is_some() {
            assert!(
                Instant::now() < deadline,
                "retirement must reclaim the launch registration"
            );
            assert_ne!(auth.coordinator.phase(registration), Some(Phase::Active));
            auth.tick();
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(auth.coordinator.phase(registration), None);
        previous = Some(registration);
    }
}
