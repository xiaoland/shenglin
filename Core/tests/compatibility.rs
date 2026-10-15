use base64::{engine::general_purpose::STANDARD as B64, Engine};
use shenglin_core::*;
fn key() -> Vec<u8> {
    (0..32).collect()
}
#[test]
fn old_swift_wire_vectors() {
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/legacy-vectors.json")).unwrap();
    let key = B64.decode(fixture["key"].as_str().unwrap()).unwrap();
    for value in fixture["updates"].as_array().unwrap() {
        let old = decode_update(value.to_string()).unwrap();
        let new = sign_update(
            old.origin.clone(),
            old.revision,
            old.quiet,
            old.known,
            old.valid_until,
            old.target_milli,
            key.clone(),
        );
        assert_eq!(new.signature, old.signature);
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&encode_update(new)).unwrap(),
            *value
        );
        assert!(valid_update(
            old,
            key.clone(),
            "initiator".into(),
            fixture["now"].as_i64().unwrap()
        ));
    }
    let old = decode_ack(fixture["ack"].to_string()).unwrap();
    assert_eq!(
        sign_ack(
            old.origin.clone(),
            old.revision,
            old.quiet,
            old.result.clone(),
            old.target_milli,
            key.clone()
        )
        .signature,
        old.signature
    );
    assert!(valid_ack(old, key, "responder".into()));
}
#[test]
fn ledger_unknown_manual_unsigned_and_restore() {
    let l = DemandLedger::new();
    let u = |r, q, k, until| sign_update("a".into(), r, q, k, until, None, key());
    assert!(
        l.accept(u(1, true, true, 120), "a".into(), "a".into(), key(), 100)
            .started
    );
    l.take_over(101);
    assert!(
        !l.accept(u(1, false, true, 122), "a".into(), "a".into(), key(), 102)
            .accepted
    );
    assert!(
        l.accept(u(2, false, false, 125), "a".into(), "a".into(), key(), 105)
            .accepted
    );
    assert_eq!(l.snapshot().records["a"].valid_until, Some(120));
    let copy = DemandLedger::new();
    copy.load_snapshot(l.snapshot());
    let end = copy.expire(120);
    assert!(end.ended && end.manual_at_end);
    assert!(!copy.snapshot().manual_takeover);
    assert!(
        l.accept(
            u(u64::MAX, true, true, 130),
            "a".into(),
            "a".into(),
            key(),
            110
        )
        .accepted
    );
    assert!(
        !l.accept(u(3, false, true, 130), "a".into(), "a".into(), key(), 110)
            .accepted
    );
    assert!(l.stop_responding(Some("a".into()), 111).ended);
    assert_eq!(l.snapshot().records["a"].revision, u64::MAX);
}
#[test]
fn pairing_v3_v4_roundtrip_wrong_code_expiry() {
    for p in [None, Some("android".to_string())] {
        let i =
            RustPairingInitiator::new("123456".into(), "手机👩‍💻".into(), p.clone(), 100.).unwrap();
        let start = decode_pairing(encode_pairing(i.start_frame())).unwrap();
        let r = RustPairingResponder::new(
            start,
            "123456".into(),
            "iPad".into(),
            "iPad".into(),
            p.clone(),
            100.,
        )
        .unwrap();
        let c = i.receive_offer(r.offer_frame(), 101.).unwrap();
        let f = r.receive_confirm(c, 102.).unwrap();
        assert_eq!(
            i.receive_finish(f, 103.).unwrap(),
            r.confirmed_key().unwrap()
        );
        assert!(matches!(
            r.receive_confirm(i.start_frame(), 104.),
            Err(CoreError::WrongStep)
        ));
    }
    let i = RustPairingInitiator::new("123456".into(), "Mac".into(), None, 0.).unwrap();
    let r = RustPairingResponder::new(
        i.start_frame(),
        "654321".into(),
        "iPad".into(),
        "iPad".into(),
        None,
        0.,
    )
    .unwrap();
    let c = i.receive_offer(r.offer_frame(), 1.).unwrap();
    assert!(matches!(
        r.receive_confirm(c, 2.),
        Err(CoreError::WrongCode)
    ));
    let i = RustPairingInitiator::new("123456".into(), "Mac".into(), None, 0.).unwrap();
    let r = RustPairingResponder::new(
        i.start_frame(),
        "123456".into(),
        "iPad".into(),
        "iPad".into(),
        None,
        0.,
    )
    .unwrap();
    assert!(matches!(
        i.receive_offer(r.offer_frame(), 90.),
        Err(CoreError::Expired)
    ));
}
#[test]
fn malformed_and_temporal_boundaries() {
    let u = sign_update("a".into(), 1, true, true, 125, Some(500), key());
    assert!(valid_update(u.clone(), key(), "a".into(), 100));
    assert!(!valid_update(u.clone(), key(), "a".into(), 99));
    assert!(!valid_update(u, key(), "a".into(), 125));
    for j in [
        r#"{"origin":"a","revision":-1,"quiet":true,"known":true,"validUntil":120,"signature":""}"#,
        r#"{"origin":"a","revision":1.5,"quiet":true,"known":true,"validUntil":120,"signature":""}"#,
    ] {
        assert!(decode_update(j.into()).is_err())
    }
    let g = RustSpaceGate::new();
    assert!(g.allows(true, true, true, 100));
    assert!(g.allows(true, false, true, 119));
    assert!(!g.allows(true, false, true, 120));
    g.reset();
    assert!(!g.allows(true, false, true, 100));
}

#[test]
fn legacy_names_and_network_proofs() {
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/legacy-vectors.json")).unwrap();
    for entry in fixture["nameClaims"].as_array().unwrap() {
        let claim = decode_name(entry["claim"].to_string()).unwrap();
        assert!(valid_name(claim.clone(), key()));
        // The fixture displays control characters escaped for review.
        let input = entry["input"]
            .as_str()
            .unwrap()
            .replace("\\n", "\n")
            .replace("\\u200d", "\u{200d}")
            .replace("\\u200b", "\u{200b}")
            .replace("\\x01", "\u{1}");
        assert_eq!(sign_name(input, key()).signature, claim.signature);
    }
    let nonce = B64.encode((0u8..16).collect::<Vec<_>>());
    // Authentication validates the original wire bytes, including optional medium evidence.
    let signature = wifi_proof_sign("initiator".into(), nonce.clone(), key());
    assert!(wifi_proof_valid(
        signature,
        "initiator".into(),
        nonce.clone(),
        key()
    ));
    let signature =
        network_medium_proof_sign("responder".into(), nonce.clone(), "ethernet".into(), key())
            .unwrap();
    assert!(network_medium_proof_valid(
        signature.clone(),
        "responder".into(),
        nonce.clone(),
        "ethernet".into(),
        key()
    ));
    assert!(!network_medium_proof_valid(
        signature,
        "responder".into(),
        nonce,
        "wifi".into(),
        key()
    ));
}

#[test]
fn link_proof_needs_matching_fresh_signed_ack() {
    let p = LinkProof::new();
    p.sent(sign_update(
        "initiator".into(),
        u64::MAX,
        true,
        true,
        120,
        None,
        key(),
    ));
    let wrong = sign_ack(
        "responder".into(),
        u64::MAX,
        false,
        "applied".into(),
        None,
        key(),
    );
    assert!(!p.accept(wrong, key(), "responder".into(), 101, 1000));
    let good = sign_ack(
        "responder".into(),
        u64::MAX,
        true,
        "applied".into(),
        None,
        key(),
    );
    assert!(p.accept(good.clone(), key(), "responder".into(), 101, 1000));
    assert!(!p.accept(good, key(), "responder".into(), 101, 1001));
    assert!(!p.verified(999));
    assert!(p.verified(20999));
    assert!(!p.verified(21000));
    p.clear();
    assert!(!p.verified(2000));
}

#[test]
fn old_swift_ledger_trace() {
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/legacy-vectors.json")).unwrap();
    let now = fixture["now"].as_i64().unwrap();
    let ledger = DemandLedger::new();
    for step in fixture["ledgerTrace"].as_array().unwrap() {
        let event = step["event"].as_str().unwrap();
        let update = |revision, known, until| {
            sign_update(
                "initiator".into(),
                revision,
                true,
                known,
                until,
                None,
                key(),
            )
        };
        let change = match event {
            "start" => ledger.accept(
                update(1, true, now + 20),
                "a".into(),
                "initiator".into(),
                key(),
                now,
            ),
            "duplicate" => ledger.accept(
                update(1, true, now + 20),
                "a".into(),
                "initiator".into(),
                key(),
                now + 1,
            ),
            "unknown" => ledger.accept(
                update(2, false, now + 25),
                "a".into(),
                "initiator".into(),
                key(),
                now + 5,
            ),
            "expire" => {
                ledger.take_over(now + 6);
                ledger.expire(now + 20)
            }
            "highRevision" => ledger.accept(
                update(u64::MAX, true, now + 41),
                "a".into(),
                "initiator".into(),
                key(),
                now + 21,
            ),
            "oldRevision" => ledger.accept(
                update(3, true, now + 42),
                "a".into(),
                "initiator".into(),
                key(),
                now + 22,
            ),
            "removePeer" => ledger.stop_responding(Some("a".into()), now + 23),
            _ => panic!("unknown fixture event"),
        };
        assert_eq!(
            change.started,
            step["started"].as_bool().unwrap(),
            "{event}"
        );
        assert_eq!(change.ended, step["ended"].as_bool().unwrap(), "{event}");
        assert_eq!(
            change.accepted,
            step["accepted"].as_bool().unwrap(),
            "{event}"
        );
        assert_eq!(
            change.manual_at_end,
            step["manualAtEnd"].as_bool().unwrap(),
            "{event}"
        );
        assert_eq!(
            change.active_count as u64,
            step["activeCount"].as_u64().unwrap(),
            "{event}"
        );
        let expected: LedgerSnapshot = serde_json::from_value(step["snapshot"].clone()).unwrap();
        let actual = ledger.snapshot();
        assert_eq!(actual.manual_takeover, expected.manual_takeover);
        assert_eq!(actual.records.len(), expected.records.len());
        for (source, record) in expected.records {
            assert_eq!(actual.records[&source].revision, record.revision);
            assert_eq!(actual.records[&source].valid_until, record.valid_until);
        }
    }
}

#[test]
fn android_local_observation_preserves_legacy_unknown_policy() {
    // Native Apple observation policy is intentionally not inferred from this Android policy.
    let cases = [
        // enabled, known input, recording, space, paused, expected known, expected quiet
        (true, true, true, true, false, true, true),
        (true, false, false, true, false, false, false),
        (true, false, false, false, false, true, false),
        (true, false, false, true, true, true, false),
        (false, false, false, true, false, false, false),
        (false, true, true, true, false, true, false),
    ];
    for (enabled, known, recording, space, paused, expected_known, expected_quiet) in cases {
        let update = local_update(
            "initiator".into(),
            1,
            enabled,
            known,
            recording,
            space,
            paused,
            100,
            None,
            key(),
        );
        assert_eq!(update.known, expected_known);
        assert_eq!(update.quiet, expected_quiet);
        assert_eq!(update.valid_until, 120);
        assert!(valid_update(update, key(), "initiator".into(), 100));
    }
}
