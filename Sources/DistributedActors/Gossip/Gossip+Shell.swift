//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging

private let gossipTickKey: TimerKey = "gossip-tick"

/// Convergent gossip is a gossip mechanism which aims to equalize some state across all peers participating.
internal final class GossipShell<Envelope: GossipEnvelopeProtocol> {
    typealias Ref = ActorRef<Message>

    let settings: Gossiper.Settings

    private let makeLogic: (ActorContext<Message>, GossipIdentifier) -> AnyGossipLogic<Envelope>

    /// Payloads to be gossiped on gossip rounds
    private var gossipLogics: [AnyGossipIdentifier: AnyGossipLogic<Envelope>]

    typealias PeerRef = ActorRef<Message>
    private var peers: Set<PeerRef>

    fileprivate init<Logic>(
        settings: Gossiper.Settings,
        makeLogic: @escaping (Logic.Context) -> Logic
    ) where Logic: GossipLogic, Logic.Envelope == Envelope {
        self.settings = settings
        self.makeLogic = { shellContext, id in
            let logicContext = GossipLogicContext(ownerContext: shellContext, gossipIdentifier: id)
            let logic = makeLogic(logicContext)
            return AnyGossipLogic(logic)
        }
        self.gossipLogics = [:]
        self.peers = []
    }

    var behavior: Behavior<Message> {
        .setup { context in
            self.ensureNextGossipRound(context)
            self.initPeerDiscovery(context)

            return Behavior<Message>.receiveMessage {
                switch $0 {
                case .updatePayload(let identifier, let payload):
                    self.onLocalPayloadUpdate(context, identifier: identifier, payload: payload)
                case .removePayload(let identifier):
                    self.onLocalPayloadRemove(context, identifier: identifier)

                case .introducePeer(let peer):
                    self.onIntroducePeer(context, peer: peer)

                case .sideChannelMessage(let identifier, let message):
                    switch self.onSideChannelMessage(context, identifier: identifier, message) {
                    case .received: () // ok
                    case .unhandled: return .unhandled
                    }

                case .gossip(let identity, let origin, let payload, let ackRef):
                    self.receiveGossip(context, identifier: identity, origin: origin, payload: payload, ackRef: ackRef)

                case ._periodicGossipTick:
                    self.runGossipRound(context)
                }
                return .same
            }.receiveSpecificSignal(Signals.Terminated.self) { context, terminated in
                context.log.trace("Peer terminated: \(terminated.address), will not gossip to it anymore")
                self.peers = self.peers.filter {
                    $0.address != terminated.address
                }
                if self.peers.isEmpty {
                    context.log.trace("No peers available, cancelling periodic gossip timer")
                    context.timers.cancel(for: gossipTickKey)
                }
                return .same
            }
        }
    }

    private func receiveGossip(
        _ context: ActorContext<Message>,
        identifier: GossipIdentifier,
        origin: ActorRef<Message>,
        payload: Envelope,
        ackRef: ActorRef<GossipACK>
    ) {
        context.log.trace("Received gossip [\(identifier.gossipIdentifier)]", metadata: [
            "gossip/identity": "\(identifier.gossipIdentifier)",
            "gossip/origin": "\(origin.address)",
            "gossip/incoming": Logger.MetadataValue.pretty(payload),
        ])

        // TODO: we could handle some actions if it issued some
        let logic: AnyGossipLogic<Envelope> = self.getEnsureLogic(context, identifier: identifier)

        // TODO: we could handle directives from the logic
        logic.receiveGossip(origin: origin.asAddressable(), payload: payload)

        ackRef.tell(.init()) // TODO: allow the user to return an ACK from receiveGossip
    }

    private func onLocalPayloadUpdate(
        _ context: ActorContext<Message>,
        identifier: GossipIdentifier,
        payload: Envelope
    ) {
        let logic = self.getEnsureLogic(context, identifier: identifier)

        logic.localGossipUpdate(payload: payload)

        context.log.trace("Gossip payload [\(identifier.gossipIdentifier)] (locally) updated", metadata: [
            "gossip/identifier": "\(identifier.gossipIdentifier)",
            "gossip/payload": "\(pretty: payload)",
        ])

        // TODO: bump local version vector; once it is in the envelope
    }

    private func getEnsureLogic(_ context: ActorContext<Message>, identifier: GossipIdentifier) -> AnyGossipLogic<Envelope> {
        let logic: AnyGossipLogic<Envelope>
        if let existing = self.gossipLogics[identifier.asAnyGossipIdentifier] {
            logic = existing
        } else {
            logic = self.makeLogic(context, identifier)
            self.gossipLogics[identifier.asAnyGossipIdentifier] = logic
        }
        return logic
    }

    // TODO: keep and remove logics
    private func onLocalPayloadRemove(_ context: ActorContext<Message>, identifier: GossipIdentifier) {
        let identifierKey = identifier.asAnyGossipIdentifier

        _ = self.gossipLogics.removeValue(forKey: identifierKey)
        context.log.trace("Removing gossip identified by [\(identifier)]", metadata: [
            "gossip/identifier": "\(identifier)",
        ])

        // TODO: callback into client or not?
    }

    private func runGossipRound(_ context: ActorContext<Message>) {
        defer {
            self.ensureNextGossipRound(context)
        }

        let allPeers: [AddressableActorRef] = Array(self.peers).map { $0.asAddressable() } // TODO: some protocol Addressable so we can avoid this mapping?

        guard !allPeers.isEmpty else {
            // no members to gossip with, skip this round
            return
        }

        for (identifier, logic) in self.gossipLogics {
            let selectedPeers = logic.selectPeers(peers: allPeers) // TODO: OrderedSet would be the right thing here...

            context.log.trace("New gossip round, selected [\(selectedPeers.count)] peers, from [\(allPeers.count)] peers", metadata: [
                "gossip/id": "\(identifier.gossipIdentifier)",
                "gossip/peers/selected": Logger.MetadataValue.array(selectedPeers.map { "\($0)" }),
            ])

            for selectedPeer in selectedPeers {
                guard let payload: Envelope = logic.makePayload(target: selectedPeer) else {
                    context.log.trace("Skipping gossip to peer \(selectedPeer)", metadata: [
                        "gossip/id": "\(identifier.gossipIdentifier)",
                        "gossip/target": "\(selectedPeer)",
                    ])
                    continue
                }

                // a bit annoying that we have to do this dance, but we don't want to let the logic do the sending,
                // types would be wrong, and logging and more lost
                guard let selectedRef = selectedPeer.ref as? PeerRef else {
                    context.log.trace("Selected peer \(selectedPeer) is not of \(PeerRef.self) type! GossipLogic attempted to gossip to unknown actor?", metadata: [
                        "gossip/id": "\(identifier.gossipIdentifier)",
                        "gossip/target": "\(selectedPeer)",
                    ])
                    continue
                }

//                pprint("""
//                       [\(context.system.cluster.node)] \
//                       Selected [\(selectedPeers.count)] peers, \
//                       from [\(allPeers.count)] peers: \(selectedPeers)\
//                       PAYLOAD: \(pretty: payload)
//                       """)

                self.sendGossip(context, identifier: identifier, payload, to: selectedRef, onAck: {
                    logic.receivePayloadACK(target: selectedPeer, confirmedDeliveryOf: payload)
                })
            }

            // TODO: signal "gossip round complete" perhaps?
            // it would allow for "speed up" rounds, as well as "remove me, we're done"
        }
    }

    private func sendGossip(
        _ context: ActorContext<Message>,
        identifier: AnyGossipIdentifier,
        _ payload: Envelope,
        to target: PeerRef,
        onAck: @escaping () -> Void
    ) {
        context.log.trace("Sending gossip to \(target.address)", metadata: [
            "gossip/target": "\(target.address)",
            "gossip/peers/count": "\(self.peers.count)",
            "actor/message": Logger.MetadataValue.pretty(payload),
        ])

        let ack = target.ask(for: GossipACK.self, timeout: .seconds(3)) { replyTo in
            Message.gossip(identity: identifier.underlying, origin: context.myself, payload, ackRef: replyTo)
        }

        context.onResultAsync(of: ack, timeout: .effectivelyInfinite) { res in
            switch res {
            case .success(let ack):
                context.log.trace("Gossip ACKed", metadata: [
                    "gossip/ack": "\(ack)",
                ])
                onAck()
            case .failure:
                context.log.warning("Failed to ACK delivery [\(identifier.gossipIdentifier)] gossip \(payload) to \(target)")
            }
            return .same
        }
    }

    private func ensureNextGossipRound(_ context: ActorContext<Message>) {
        guard !self.peers.isEmpty else {
            return // no need to schedule gossip ticks if we have no peers
        }

        let delay = self.settings.effectiveGossipInterval
        context.log.trace("Schedule next gossip round in \(delay.prettyDescription) (\(self.settings.gossipInterval.prettyDescription) ± \(self.settings.gossipIntervalRandomFactor * 100)%)")
        context.timers.startSingle(key: gossipTickKey, message: ._periodicGossipTick, delay: delay)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ConvergentGossip: Peer Discovery

extension GossipShell {
    public static func receptionKey(id: String) -> Receptionist.RegistrationKey<Message> {
        Receptionist.RegistrationKey<Message>(id)
    }

    private func initPeerDiscovery(_ context: ActorContext<Message>) {
        switch self.settings.peerDiscovery {
        case .manuallyIntroduced:
            return // nothing to do, peers will be introduced manually

        case .onClusterMember(let atLeastStatus, let resolvePeerOn):
            func resolveInsertPeer(_ context: ActorContext<Message>, member: Cluster.Member) {
                guard member.node != context.system.cluster.node else {
                    return // ignore self node
                }

                guard atLeastStatus <= member.status else {
                    return // too "early" status of the member
                }

                let resolved: AddressableActorRef = resolvePeerOn(member)
                if let peer = resolved.ref as? PeerRef {
                    if self.peers.insert(peer).inserted {
                        context.log.debug("Automatically discovered peer", metadata: [
                            "gossip/peer": "\(peer)",
                            "gossip/peerCount": "\(self.peers.count)",
                            "gossip/peers": "\(self.peers.map { $0.address })",
                        ])
                    }
                } else {
                    context.log.warning("Resolved reference \(resolved.ref) is not \(PeerRef.self), can not use it as peer for gossip.")
                }
            }

            let onClusterEventRef = context.subReceive(Cluster.Event.self) { event in
                switch event {
                case .snapshot(let membership):
                    for member in membership.members(atLeast: .joining) {
                        resolveInsertPeer(context, member: member)
                    }
                case .membershipChange(let change):
                    resolveInsertPeer(context, member: change.member)
                case .leadershipChange, .reachabilityChange:
                    () // ignore
                }
            }
            context.system.cluster.events.subscribe(onClusterEventRef)

        case .fromReceptionistListing(let id):
            let key = Receptionist.RegistrationKey<Message>(id)
            context.system.receptionist.register(context.myself, key: key)
            context.log.debug("Registered with receptionist key: \(key)")

            context.system.receptionist.subscribe(key: key, subscriber: context.subReceive(Receptionist.Listing.self) { listing in
                context.log.trace("Peer listing update via receptionist", metadata: [
                    "peer/listing": Logger.MetadataValue.array(
                        listing.refs.map { ref in Logger.MetadataValue.stringConvertible(ref) }
                    ),
                ])
                for peer in listing.refs {
                    self.onIntroducePeer(context, peer: peer)
                }
            })
        }
    }

    private func onIntroducePeer(_ context: ActorContext<Message>, peer: PeerRef) {
        guard peer != context.myself else {
            return // there is never a need to gossip to myself
        }

        if self.peers.insert(context.watch(peer)).inserted {
            context.log.trace("Got introduced to peer [\(peer)]", metadata: [
                "gossip/peerCount": "\(self.peers.count)",
                "gossip/peers": "\(self.peers.map { $0.address })",
            ])

//            // TODO: implement this rather as "high priority peer to gossip to"
//            // TODO: remove this most likely
//            // TODO: or rather, ask the logic if it wants to eagerly push?
//            for (key, logic) in self.gossipLogics {
//                self.sendGossip(context, identifier: key.identifier, logic.payload, to: peer)
//            }

            self.ensureNextGossipRound(context)
        }
    }

    enum SideChannelDirective {
        case received
        case unhandled
    }

    private func onSideChannelMessage(_ context: ActorContext<Message>, identifier: GossipIdentifier, _ message: Any) -> SideChannelDirective {
        guard let logic = self.gossipLogics[identifier.asAnyGossipIdentifier] else {
            return .unhandled
        }

        do {
            try logic.receiveSideChannelMessage(message)
        } catch {
            context.log.error("Gossip logic \(logic) [\(identifier)] receiveSideChannelMessage failed: \(error)")
            return .received
        }

        return .received
    }
}

extension GossipShell {
    enum Message {
        // gossip
        case gossip(identity: GossipIdentifier, origin: ActorRef<Message>, Envelope, ackRef: ActorRef<GossipACK>)

        // local messages
        case updatePayload(identifier: GossipIdentifier, Envelope)
        case removePayload(identifier: GossipIdentifier)
        case introducePeer(PeerRef)

        case sideChannelMessage(identifier: GossipIdentifier, Any)

        // internal messages
        case _periodicGossipTick
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Gossiper

/// A Gossiper
public enum Gossiper {
    /// Spawns a gossip actor, that will periodically gossip with its peers about the provided payload.
    static func start<Envelope, Logic>(
        _ context: ActorRefFactory, name naming: ActorNaming,
        of type: Envelope.Type = Envelope.self,
        props: Props = .init(),
        settings: Settings = .init(),
        makeLogic: @escaping (Logic.Context) -> Logic
    ) throws -> GossipControl<Envelope>
        where Logic: GossipLogic, Logic.Envelope == Envelope {
        let ref = try context.spawn(
            naming,
            of: GossipShell<Envelope>.Message.self,
            props: props,
            file: #file, line: #line,
            GossipShell<Envelope>(settings: settings, makeLogic: makeLogic).behavior
        )
        return GossipControl(ref)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: GossipControl

internal struct GossipControl<GossipEnvelope: GossipEnvelopeProtocol> {
    private let ref: GossipShell<GossipEnvelope>.Ref

    init(_ ref: GossipShell<GossipEnvelope>.Ref) {
        self.ref = ref
    }

    /// Introduce a peer to the gossip group
    func introduce(peer: GossipShell<GossipEnvelope>.Ref) {
        self.ref.tell(.introducePeer(peer))
    }

    // FIXME: is there some way to express that actually, Metadata is INSIDE Payload so I only want to pass the "envelope" myself...?
    func update(_ identifier: GossipIdentifier, payload: GossipEnvelope) {
        self.ref.tell(.updatePayload(identifier: identifier, payload))
    }

    func remove(_ identifier: GossipIdentifier) {
        self.ref.tell(.removePayload(identifier: identifier))
    }

    /// Side channel messages which may be piped into specific gossip logics.
    func sideChannelTell(_ identifier: GossipIdentifier, message: Any) {
        self.ref.tell(.sideChannelMessage(identifier: identifier, message))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Gossip Identifier

/// Used to identify which identity a payload is tied with.
/// E.g. it could be used to mark the CRDT instance the gossip is carrying, or which "entity" a gossip relates to.
// FIXME: just force GossipIdentifier to be codable, avoid this hacky dance?
public protocol GossipIdentifier {
    var gossipIdentifier: String { get }

    init(_ gossipIdentifier: String)

    var asAnyGossipIdentifier: AnyGossipIdentifier { get }
}

public struct AnyGossipIdentifier: Hashable, GossipIdentifier {
    public let underlying: GossipIdentifier

    public init(_ id: String) {
        self.underlying = StringGossipIdentifier(stringLiteral: id)
    }

    public init(_ identifier: GossipIdentifier) {
        if let any = identifier as? AnyGossipIdentifier {
            self = any
        } else {
            self.underlying = identifier
        }
    }

    public var gossipIdentifier: String {
        self.underlying.gossipIdentifier
    }

    public var asAnyGossipIdentifier: AnyGossipIdentifier {
        self
    }

    public func hash(into hasher: inout Hasher) {
        self.underlying.gossipIdentifier.hash(into: &hasher)
    }

    public static func == (lhs: AnyGossipIdentifier, rhs: AnyGossipIdentifier) -> Bool {
        lhs.underlying.gossipIdentifier == rhs.underlying.gossipIdentifier
    }
}

public struct StringGossipIdentifier: GossipIdentifier, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let gossipIdentifier: String

    public init(_ gossipIdentifier: StringLiteralType) {
        self.gossipIdentifier = gossipIdentifier
    }

    public init(stringLiteral gossipIdentifier: StringLiteralType) {
        self.gossipIdentifier = gossipIdentifier
    }

    public var asAnyGossipIdentifier: AnyGossipIdentifier {
        AnyGossipIdentifier(self)
    }

    public var description: String {
        "StringGossipIdentifier(\(self.gossipIdentifier))"
    }
}