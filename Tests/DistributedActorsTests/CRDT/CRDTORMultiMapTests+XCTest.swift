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

import XCTest

///
/// NOTE: This file was generated by generate_linux_tests.rb
///
/// Do NOT edit this file directly as it will be regenerated automatically when needed.
///

extension CRDTORMultiMapTests {
    static var allTests: [(String, (CRDTORMultiMapTests) -> () throws -> Void)] {
        return [
            ("test_ORMultiMap_basicOperations", test_ORMultiMap_basicOperations),
            ("test_ORMultiMap_GCounter_add_remove_shouldUpdateDelta", test_ORMultiMap_GCounter_add_remove_shouldUpdateDelta),
            ("test_ORMultiMap_merge_shouldMutate", test_ORMultiMap_merge_shouldMutate),
            ("test_ORMultiMap_mergeDelta_shouldMutate", test_ORMultiMap_mergeDelta_shouldMutate),
            ("test_ORMultiMap_removeAll", test_ORMultiMap_removeAll),
        ]
    }
}