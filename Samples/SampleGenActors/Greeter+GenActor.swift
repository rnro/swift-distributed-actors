// ==== ------------------------------------------------------------------ ====
// === DO NOT EDIT: Generated by GenActors                     
// ==== ------------------------------------------------------------------ ====

import DistributedActors

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated Greeter messages 

/// DO NOT EDIT: Generated Greeter messages
extension Greeter {
    public enum Message { 
        case greet(name: String) 
    }

    
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated Greeter behavior

extension Greeter {

    // TODO: if overriden don't generate this?
    // public typealias Message = Actor<Greeter>.GreeterMessage

    public static func makeBehavior(instance: Greeter) -> Behavior<Message> {
        return .setup { context in
            var instance = instance // TODO only var if any of the methods are mutating

            // /* await */ self.instance.preStart(context: context) // TODO: enable preStart

            return .receiveMessage { message in
                switch message { 
                
                case .greet(let name):
                    instance.greet(name: name) 
                
                }
                return .same
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Extend Actor for Greeter

extension Actor where A.Message == Greeter.Message {
    
     func greet(name: String) { 
        self.ref.tell(.greet(name: name))
    } 
    
}

