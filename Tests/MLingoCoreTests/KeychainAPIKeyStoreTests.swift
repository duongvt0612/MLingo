import Foundation
import Security
import Testing
@testable import MLingoCore

@Test
func keychainStoreLoadsFoundAndMissingItems() throws {
    let foundClient = TestKeychainItemClient(readResult: .found(Data("sk-found".utf8)))
    let foundStore = KeychainAPIKeyStore(
        service: "test-service",
        account: "test-account",
        client: foundClient
    )
    #expect(try foundStore.loadAPIKey() == "sk-found")

    let missingStore = KeychainAPIKeyStore(
        service: "test-service",
        account: "test-account",
        client: TestKeychainItemClient(readResult: .notFound)
    )
    #expect(try missingStore.loadAPIKey() == nil)
}

@Test
func keychainStoreMapsReadFailureAndInvalidData() {
    let failedStore = KeychainAPIKeyStore(
        service: "test-service",
        account: "test-account",
        client: TestKeychainItemClient(readResult: .failure(errSecAuthFailed))
    )
    #expect(throws: MLingoError.credentialStoreFailure(operation: .load, status: errSecAuthFailed)) {
        try failedStore.loadAPIKey()
    }

    let invalidStore = KeychainAPIKeyStore(
        service: "test-service",
        account: "test-account",
        client: TestKeychainItemClient(readResult: .found(Data([0xFF])))
    )
    #expect(throws: MLingoError.credentialStoreFailure(operation: .load, status: errSecDecode)) {
        try invalidStore.loadAPIKey()
    }
}

@Test
func keychainStoreUpdatesExistingItemAndAddsMissingItem() throws {
    let updateClient = TestKeychainItemClient(readResult: .found(Data("old".utf8)))
    let updateStore = KeychainAPIKeyStore(
        service: "test-service",
        account: "test-account",
        client: updateClient
    )
    try updateStore.saveAPIKey("new")
    #expect(updateClient.updatedValues == [Data("new".utf8)])
    #expect(updateClient.addedValues.isEmpty)

    let addClient = TestKeychainItemClient(readResult: .notFound)
    let addStore = KeychainAPIKeyStore(
        service: "test-service",
        account: "test-account",
        client: addClient
    )
    try addStore.saveAPIKey("first")
    #expect(addClient.addedValues == [Data("first".utf8)])
    #expect(addClient.updatedValues.isEmpty)
}

@Test
func keychainStoreRecoversWhenAddRacesWithAnotherWriter() throws {
    let client = TestKeychainItemClient(
        readResult: .notFound,
        addStatus: errSecDuplicateItem
    )
    let store = KeychainAPIKeyStore(
        service: "test-service",
        account: "test-account",
        client: client
    )

    try store.saveAPIKey("secret")

    #expect(client.addedValues == [Data("secret".utf8)])
    #expect(client.updatedValues == [Data("secret".utf8)])
}

@Test
func keychainStoreRecoversWhenUpdateRacesWithDeletion() throws {
    let client = TestKeychainItemClient(
        readResult: .found(Data("old".utf8)),
        updateStatus: errSecItemNotFound
    )
    let store = KeychainAPIKeyStore(
        service: "test-service",
        account: "test-account",
        client: client
    )

    try store.saveAPIKey("secret")

    #expect(client.updatedValues == [Data("secret".utf8)])
    #expect(client.addedValues == [Data("secret".utf8)])
}

@Test
func keychainStoreMapsRaceFallbackFailuresToTheFallbackOperation() {
    let updateClient = TestKeychainItemClient(
        readResult: .notFound,
        addStatus: errSecDuplicateItem,
        updateStatus: errSecAuthFailed
    )
    let updateStore = KeychainAPIKeyStore(
        service: "test-service",
        account: "test-account",
        client: updateClient
    )
    #expect(
        throws: MLingoError.credentialStoreFailure(
            operation: .update,
            status: errSecAuthFailed
        )
    ) {
        try updateStore.saveAPIKey("secret")
    }

    let addClient = TestKeychainItemClient(
        readResult: .found(Data("old".utf8)),
        addStatus: errSecAuthFailed,
        updateStatus: errSecItemNotFound
    )
    let addStore = KeychainAPIKeyStore(
        service: "test-service",
        account: "test-account",
        client: addClient
    )
    #expect(
        throws: MLingoError.credentialStoreFailure(
            operation: .add,
            status: errSecAuthFailed
        )
    ) {
        try addStore.saveAPIKey("secret")
    }
}

@Test
func keychainStoreDoesNotAddAfterLookupFailure() {
    let client = TestKeychainItemClient(readResult: .failure(errSecInteractionNotAllowed))
    let store = KeychainAPIKeyStore(
        service: "test-service",
        account: "test-account",
        client: client
    )

    #expect(
        throws: MLingoError.credentialStoreFailure(
            operation: .inspect,
            status: errSecInteractionNotAllowed
        )
    ) {
        try store.saveAPIKey("secret")
    }
    #expect(client.addedValues.isEmpty)
    #expect(client.updatedValues.isEmpty)
}

@Test
func keychainStoreMapsAddUpdateAndDeleteFailures() {
    let addClient = TestKeychainItemClient(
        readResult: .notFound,
        addStatus: errSecAuthFailed
    )
    let addStore = KeychainAPIKeyStore(
        service: "test-service",
        account: "test-account",
        client: addClient
    )
    #expect(throws: MLingoError.credentialStoreFailure(operation: .add, status: errSecAuthFailed)) {
        try addStore.saveAPIKey("secret")
    }

    let updateClient = TestKeychainItemClient(
        readResult: .found(Data()),
        updateStatus: errSecAuthFailed
    )
    let updateStore = KeychainAPIKeyStore(
        service: "test-service",
        account: "test-account",
        client: updateClient
    )
    #expect(
        throws: MLingoError.credentialStoreFailure(operation: .update, status: errSecAuthFailed)
    ) {
        try updateStore.saveAPIKey("secret")
    }

    let deleteClient = TestKeychainItemClient(
        readResult: .notFound,
        deleteStatus: errSecAuthFailed
    )
    let deleteStore = KeychainAPIKeyStore(
        service: "test-service",
        account: "test-account",
        client: deleteClient
    )
    #expect(
        throws: MLingoError.credentialStoreFailure(operation: .delete, status: errSecAuthFailed)
    ) {
        try deleteStore.deleteAPIKey()
    }
}

@Test(arguments: [errSecSuccess, errSecItemNotFound])
func keychainStoreDeleteIsIdempotent(_ status: OSStatus) throws {
    let client = TestKeychainItemClient(readResult: .notFound, deleteStatus: status)
    let store = KeychainAPIKeyStore(
        service: "test-service",
        account: "test-account",
        client: client
    )

    try store.deleteAPIKey()
    #expect(client.deleteCallCount == 1)
}

@Test
func keychainStoreLiveRoundTripWhenExplicitlyEnabled() throws {
    guard ProcessInfo.processInfo.environment["MLINGO_RUN_KEYCHAIN_INTEGRATION_TESTS"] == "1"
    else {
        return
    }

    let identifier = UUID().uuidString
    let store = KeychainAPIKeyStore(
        service: "com.duongvt.MLingo.tests.\(identifier)",
        account: "openai-api-key"
    )
    defer { try? store.deleteAPIKey() }

    try store.saveAPIKey("sk-first")
    #expect(try store.loadAPIKey() == "sk-first")
    try store.saveAPIKey("sk-second")
    #expect(try store.loadAPIKey() == "sk-second")
    try store.deleteAPIKey()
    #expect(try store.loadAPIKey() == nil)
}

private final class TestKeychainItemClient: KeychainItemClientProtocol, @unchecked Sendable {
    var readResult: KeychainItemReadResult
    var addStatus: OSStatus
    var updateStatus: OSStatus
    var deleteStatus: OSStatus
    private(set) var addedValues: [Data] = []
    private(set) var updatedValues: [Data] = []
    private(set) var deleteCallCount = 0

    init(
        readResult: KeychainItemReadResult,
        addStatus: OSStatus = errSecSuccess,
        updateStatus: OSStatus = errSecSuccess,
        deleteStatus: OSStatus = errSecSuccess
    ) {
        self.readResult = readResult
        self.addStatus = addStatus
        self.updateStatus = updateStatus
        self.deleteStatus = deleteStatus
    }

    func read(service: String, account: String) -> KeychainItemReadResult { readResult }

    func add(_ data: Data, service: String, account: String) -> OSStatus {
        addedValues.append(data)
        return addStatus
    }

    func update(_ data: Data, service: String, account: String) -> OSStatus {
        updatedValues.append(data)
        return updateStatus
    }

    func delete(service: String, account: String) -> OSStatus {
        deleteCallCount += 1
        return deleteStatus
    }
}
