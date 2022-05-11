#define SECURITY_ACCOUNT_PREFIX QString("KeepassXC_TouchID_Keys_")

#include "touchid/TouchID.h"

#include "crypto/Random.h"
#include "crypto/SymmetricCipher.h"
#include "crypto/CryptoHash.h"

#include <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <LocalAuthentication/LocalAuthentication.h>
#include <Security/Security.h>

#include <QCoreApplication>

inline void debug(const char* message, ...)
{
    Q_UNUSED(message);
    // qWarning(...);
}

inline QString hash(const QString& value)
{
    QByteArray result = CryptoHash::hash(value.toUtf8(), CryptoHash::Sha256).toHex();
    return QString(result);
}

/**
 * Singleton
 */
TouchID& TouchID::getInstance()
{
    static TouchID instance;    // Guaranteed to be destroyed.
    // Instantiated on first use.
    return instance;
}

/**
 * Generates a random AES 256bit key and uses it to encrypt the PasswordKey that
 * protects the database. The encrypted PasswordKey is kept in memory while the
 * AES key is stored in the macOS KeyChain protected by TouchID.
 */
bool TouchID::storeKey(const QString& databasePath, const QByteArray& passwordKey)
{
    if (databasePath.isEmpty() || passwordKey.isEmpty()) {
        // illegal arguments
        debug("TouchID::storeKey - Illegal arguments: databasePath = %s, len(passwordKey) = %d",
              databasePath.toUtf8().constData(),
              passwordKey.length());
        return false;
    }

    if (this->m_encryptedMasterKeys.contains(databasePath)) {
        // already stored key for this database
        debug("TouchID::storeKey - Already stored key for this database");
        return true;
    }

    // generate random AES 256bit key and IV
    QByteArray randomKey = randomGen()->randomArray(SymmetricCipher::keySize(SymmetricCipher::Aes256_GCM));
    QByteArray randomIV = randomGen()->randomArray(SymmetricCipher::defaultIvSize(SymmetricCipher::Aes256_GCM));

    SymmetricCipher aes256Encrypt;
    if (!aes256Encrypt.init(SymmetricCipher::Aes256_GCM, SymmetricCipher::Encrypt, randomKey, randomIV)) {
        debug("TouchID::storeKey - Error initializing encryption: %s",
              aes256Encrypt.errorString().toUtf8().constData());
        return false;
    }

    // encrypt and keep result in memory
    QByteArray encryptedMasterKey = passwordKey;
    if (!aes256Encrypt.finish(encryptedMasterKey)) {
        debug("TouchID::storeKey - Error encrypting: %s", aes256Encrypt.errorString().toUtf8().constData());
        debug(aes256Encrypt.errorString().toUtf8().constData());
        return false;
    }

    // memorize which database the stored key is for
    m_encryptedMasterKeys.insert(databasePath, encryptedMasterKey);

    NSString* accountName = (SECURITY_ACCOUNT_PREFIX + hash(databasePath)).toNSString(); // autoreleased

    // try to delete an existing entry
    CFMutableDictionaryRef
        query = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(query, kSecAttrAccount, (__bridge CFStringRef) accountName);
    CFDictionarySetValue(query, kSecReturnData, kCFBooleanFalse);

    // get data from the KeyChain
    OSStatus status = SecItemDelete(query);

    debug("TouchID::storeKey - Status deleting existing entry: %d", status);

    // prepare adding secure entry to the macOS KeyChain
    CFErrorRef error = NULL;
    SecAccessControlRef sacObject;
#if __clang_major__ >= 9 && MAC_OS_X_VERSION_MIN_REQUIRED >= 101500
    if (@available(macOS 10.15, *)) {
        // kSecAccessControlWatch is only available for macOS 10.15 and later
        sacObject = SecAccessControlCreateWithFlags(kCFAllocatorDefault,
                                                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                    kSecAccessControlOr | kSecAccessControlBiometryCurrentSet | kSecAccessControlWatch,
                                                    &error);
    } else {
#endif
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101201
        sacObject = SecAccessControlCreateWithFlags(kCFAllocatorDefault,
                                                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                    kSecAccessControlTouchIDCurrentSet, // depr: kSecAccessControlBiometryCurrentSet,
                                                    &error);
#endif
#if __clang_major__ >= 9 && MAC_OS_X_VERSION_MIN_REQUIRED >= 101500
    }
#endif


    if (sacObject == NULL || error != NULL) {
        NSError* e = (__bridge NSError*) error;
        debug("TouchID::storeKey - Error creating security flags: %s", e.localizedDescription.UTF8String);
        return false;
    }

    CFMutableDictionaryRef attributes =
        CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    // prepare data (key) to be stored
    QByteArray dataBytes = (randomKey + randomIV).toHex();

    CFDataRef valueData =
        CFDataCreateWithBytesNoCopy(NULL, reinterpret_cast<UInt8*>(dataBytes.data()), dataBytes.length(), NULL);

    CFDictionarySetValue(attributes, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(attributes, kSecAttrAccount, (__bridge CFStringRef) accountName);
    CFDictionarySetValue(attributes, kSecValueData, valueData);
    CFDictionarySetValue(attributes, kSecAttrSynchronizable, kCFBooleanFalse);
    CFDictionarySetValue(attributes, kSecUseAuthenticationUI, kSecUseAuthenticationUIAllow);
    CFDictionarySetValue(attributes, kSecAttrAccessControl, sacObject);

    // add to KeyChain
    status = SecItemAdd(attributes, NULL);

    debug("TouchID::storeKey - Status adding new entry: %d", status); // read w/ e.g. "security error -50" in shell

    CFRelease(sacObject);
    CFRelease(attributes);

    if (status != errSecSuccess) {
        debug("TouchID::storeKey - Not successful, resetting TouchID");
        this->m_encryptedMasterKeys.remove(databasePath);
        return false;
    }

    return true;
}

/**
 * Checks if an encrypted PasswordKey is available for the given database, tries to
 * decrypt it using the KeyChain and if successful, returns it.
 */
bool TouchID::getKey(const QString& databasePath, QByteArray& passwordKey) const
{
    passwordKey.clear();
    if (databasePath.isEmpty()) {
        // illegal arguments
        debug("TouchID::storeKey - Illegal argument: databasePath = %s", databasePath.toUtf8().constData());
        return false;
    }

    // checks if encrypted PasswordKey is available and is stored for the given database
    if (!containsKey(databasePath)) {
        debug("TouchID::getKey - No stored key found");
        return false;
    }

    // query the KeyChain for the AES key
    CFMutableDictionaryRef
        query = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    NSString* accountName = (SECURITY_ACCOUNT_PREFIX + hash(databasePath)).toNSString(); // autoreleased
    NSString* touchPromptMessage =
        QCoreApplication::translate("DatabaseOpenWidget", "authenticate to access the database")
            .toNSString(); // autoreleased

    CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(query, kSecAttrAccount, (__bridge CFStringRef) accountName);
    CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
    CFDictionarySetValue(query, kSecUseOperationPrompt, (__bridge CFStringRef) touchPromptMessage);

    // get data from the KeyChain
    CFTypeRef dataTypeRef = NULL;
    OSStatus status = SecItemCopyMatching(query, &dataTypeRef);
    CFRelease(query);

    if (status == errSecUserCanceled) {
        // user canceled the authentication, return true with empty key
        debug("TouchID::getKey - User canceled authentication");
        return true;
    } else if (status != errSecSuccess || dataTypeRef == NULL) {
        debug("TouchID::getKey - Error retrieving result: %d", status);
        return false;
    }

    CFDataRef valueData = static_cast<CFDataRef>(dataTypeRef);
    QByteArray dataBytes = QByteArray::fromHex(QByteArray(reinterpret_cast<const char*>(CFDataGetBytePtr(valueData)),
                                                          CFDataGetLength(valueData)));
    CFRelease(valueData);

    // extract AES key and IV from data bytes
    QByteArray key = dataBytes.left(SymmetricCipher::keySize(SymmetricCipher::Aes256_GCM));
    QByteArray iv = dataBytes.right(SymmetricCipher::defaultIvSize(SymmetricCipher::Aes256_GCM));

    SymmetricCipher aes256Decrypt;
    if (!aes256Decrypt.init(SymmetricCipher::Aes256_GCM, SymmetricCipher::Decrypt, key, iv)) {
        debug("TouchID::getKey - Error initializing decryption: %s", aes256Decrypt.errorString().toUtf8().constData());
        return false;
    }

    // decrypt PasswordKey from memory using AES
    passwordKey = m_encryptedMasterKeys[databasePath];
    if (!aes256Decrypt.finish(passwordKey)) {
        passwordKey.clear();
        debug("TouchID::getKey - Error decryption: %s", aes256Decrypt.errorString().toUtf8().constData());
        return false;
    }

    return true;
}

bool TouchID::containsKey(const QString& dbPath) const
{
    return m_encryptedMasterKeys.contains(dbPath);
}

/**
 * Dynamic check if TouchID is available on the current machine.
 */
bool TouchID::isAvailable()
{
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101201
	return false;
#else
    // cache result
    if (this->m_available != TOUCHID_UNDEFINED) {
        return (this->m_available == TOUCHID_AVAILABLE);
    }

    @try {
        LAContext* context = [[LAContext alloc] init];

        LAPolicy policyCode;
#if __clang_major__ >= 9 && MAC_OS_X_VERSION_MIN_REQUIRED >= 101500
        if (@available(macOS 10.15, *)) {
            policyCode = LAPolicyDeviceOwnerAuthenticationWithBiometricsOrWatch;
        } else {
#endif
            policyCode = LAPolicyDeviceOwnerAuthenticationWithBiometrics;
#if __clang_major__ >= 9 && MAC_OS_X_VERSION_MIN_REQUIRED >= 101500
        }
#endif

        bool canAuthenticate = [context canEvaluatePolicy:policyCode error:nil];
        [context release];
        this->m_available = canAuthenticate ? TOUCHID_AVAILABLE : TOUCHID_NOT_AVAILABLE;
        return canAuthenticate;
    }
    @catch (NSException*) {
        this->m_available = TOUCHID_NOT_AVAILABLE;
        return false;
    }
#endif
}

typedef enum
{
    kTouchIDResultNone,
    kTouchIDResultAllowed,
    kTouchIDResultFailed
} TouchIDResult;

/**
 * Performs a simple authentication using TouchID.
 */
bool TouchID::authenticate(const QString& message) const
{
    // message must not be an empty string
    QString msg = message;
    if (message.length() == 0)
        msg = QCoreApplication::translate("DatabaseOpenWidget", "authenticate a privileged operation");

    @try {
        LAContext* context = [[LAContext alloc] init];
        __block TouchIDResult result = kTouchIDResultNone;
        NSString* authMessage = msg.toNSString(); // autoreleased

        LAPolicy policyCode;
#if __clang_major__ >= 9 && MAC_OS_X_VERSION_MIN_REQUIRED >= 101500
        if (@available(macOS 10.15, *)) {
            policyCode = LAPolicyDeviceOwnerAuthenticationWithBiometricsOrWatch;
        } else {
#endif
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101201
            policyCode = LAPolicyDeviceOwnerAuthenticationWithBiometrics;
#endif
#if __clang_major__ >= 9 && MAC_OS_X_VERSION_MIN_REQUIRED >= 101500
        }
#endif

        [context evaluatePolicy:policyCode
                localizedReason:authMessage reply:^(BOOL success, NSError* error) {
                Q_UNUSED(error);
                result = success ? kTouchIDResultAllowed : kTouchIDResultFailed;
                CFRunLoopWakeUp(CFRunLoopGetCurrent());
            }];

        while (result == kTouchIDResultNone)
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true);

        [context release];
        return result == kTouchIDResultAllowed;
    }
    @catch (NSException*) {
        return false;
    }
}

/**
 * Resets the inner state either for all or for the given database
 */
void TouchID::reset(const QString& databasePath)
{
    if (databasePath.isEmpty()) {
        this->m_encryptedMasterKeys.clear();
        return;
    }

    this->m_encryptedMasterKeys.remove(databasePath);
}
