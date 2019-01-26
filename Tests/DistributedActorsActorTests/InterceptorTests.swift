//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import XCTest
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

final class ShoutingInterceptor: Interceptor<String> {
    let probe: ActorTestProbe<String>?

    init(probe: ActorTestProbe<String>? = nil) {
        self.probe = probe
    }

    override func interceptMessage(target: Behavior<String>, context: ActorContext<String>, message: String) throws -> Behavior<String> {
        self.probe?.tell("from-interceptor:\(message)")
        return try target.interpretMessage(context: context, message: message + "!")
    }

    override func isSame(as other: Interceptor<String>) -> Bool {
        return false
    }
}

final class TerminatedInterceptor<Message>: Interceptor<Message> {
    let probe: ActorTestProbe<Signals.Terminated>

    init(probe: ActorTestProbe<Signals.Terminated>) {
        self.probe = probe
    }

    override func interceptSignal(target: Behavior<Message>, context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
        switch signal {
        case let terminated as Signals.Terminated:
            self.probe.tell(terminated) // we forward all termination signals to someone
        default:
            ()
        }
        return try target.interpretSignal(context: context, signal: signal)
    }
}

class InterceptorTests: XCTestCase {

    let system = ActorSystem("ActorSystemTests")
    lazy var testKit = ActorTestKit(system)

    override func tearDown() {
        system.terminate()
    }

    func test_interceptor_shouldConvertMessages() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let interceptor = ShoutingInterceptor()

        let forwardToProbe: Behavior<String> = .receiveMessage { message in
            p.tell(message)
            return .same
        }

        let ref: ActorRef<String> = try system.spawn(
            .intercept(behavior: forwardToProbe, with: interceptor),
            name: "theWallsHaveEars")

        for i in 0...10 {
            ref.tell("hello:\(i)")
        }

        for i in 0...10 {
            try p.expectMessage("hello:\(i)!")
        }
    }

    func test_interceptor_shouldSurviveDeeplyNestedInterceptors() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()
        let i: ActorTestProbe<String> = testKit.spawnTestProbe()

        let makeStringsLouderInterceptor = ShoutingInterceptor(probe: i)

        // just like in the movie "Inception"
        func interceptionInceptionBehavior(currentDepth depth: Int, stopAt limit: Int) -> Behavior<String> {
            let behavior: Behavior<String>
            if depth < limit {
                // add another "setup layer"
                behavior = interceptionInceptionBehavior(currentDepth: depth + 1, stopAt: limit)
            } else {
                behavior = .receiveMessage { msg in
                    p.tell("received:\(msg)")
                    return .stopped
                }
            }

            return .intercept(behavior: behavior, with: makeStringsLouderInterceptor)
        }

        let ref: ActorRef<String> = try system.spawn(
            interceptionInceptionBehavior(currentDepth: 0, stopAt: 100),
            name: "theWallsHaveEars")

        ref.tell("hello")

        try p.expectMessage("received:hello!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
        for j in 0...100 {
            let m = "from-interceptor:hello\(String(repeating: "!", count: j))"
            try i.expectMessage(m)
        }
    }

    func test_interceptor_shouldInterceptSignals() throws {
        let p: ActorTestProbe<Signals.Terminated> = testKit.spawnTestProbe()

        let spyOnTerminationSignals: Interceptor<String> = TerminatedInterceptor(probe: p)

        let spawnSomeStoppers: Behavior<String> = .setup { context in
            let one: ActorRef<String> = try context.spawnWatched(.receiveMessage { msg in
                return .stopped
            }, name: "stopperOne") // entered death pact with stopperOne
            one.tell("stop")

            let two: ActorRef<String> = try context.spawnWatched(.receiveMessage { msg in
                return .stopped
            }, name: "stopperTwo") // won't handle Terminated since will die after death pact from stopperOne
            two.tell("stop")

            return .same
        }

        let _: ActorRef<String> = try system.spawn(
            .intercept(behavior: spawnSomeStoppers, with: spyOnTerminationSignals),
            name: "theWallsHaveEarsForTermination")

        let terminated = try p.expectMessage()
        terminated.path.name.shouldEqual("stopperOne")
        try p.expectNoMessage(for: .milliseconds(100))
    }

    class SignalToStringInterceptor<Message>: Interceptor<Message> {
        let probe: ActorTestProbe<String>

        init(_ probe: ActorTestProbe<String>) {
            self.probe = probe
        }

        override func interceptSignal(target: Behavior<Message>, context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
            self.probe.tell("intercepted:\(signal)")
            return try target.interpretSignal(context: context, signal: signal)
        }
    }

    func test_interceptor_shouldRemainWHenReturningStoppingWithPostStop() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = .receiveMessage { _ in
            return .stopped { _ in
                p.tell("postStop")
            }
        }

        let interceptedBahvior: Behavior<String> = .intercept(behavior: behavior, with: SignalToStringInterceptor(p))

        let ref = try system.spawnAnonymous(interceptedBahvior)
        p.watch(ref)
        ref.tell("test")

        try p.expectMessage("intercepted:PostStop()")
        try p.expectMessage("postStop")
        try p.expectTerminated(ref)
    }
}