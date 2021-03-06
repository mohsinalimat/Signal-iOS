//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

#import "OWSProfileManager.h"
#import "Environment.h"
#import "Signal-Swift.h"
#import <SignalServiceKit/NSData+hexString.h>
#import <SignalServiceKit/NSDate+OWS.h>
#import <SignalServiceKit/OWSMessageSender.h>
#import <SignalServiceKit/SecurityUtils.h>
#import <SignalServiceKit/TSGroupThread.h>
#import <SignalServiceKit/TSProfileAvatarUploadFormRequest.h>
#import <SignalServiceKit/TSSetProfileRequest.h>
#import <SignalServiceKit/TSStorageManager.h>
#import <SignalServiceKit/TSThread.h>
#import <SignalServiceKit/TSYapDatabaseObject.h>
#import <SignalServiceKit/TextSecureKitEnv.h>

NS_ASSUME_NONNULL_BEGIN

// UserProfile properties should only be mutated on the main thread.
@interface UserProfile : TSYapDatabaseObject

// These properties may be accessed from any thread.
@property (atomic, readonly) NSString *recipientId;
@property (atomic, nullable) NSData *profileKey;

// These properties may be accessed only from the main thread.
@property (nonatomic, nullable) NSString *profileName;
@property (nonatomic, nullable) NSString *avatarUrl;
@property (nonatomic, nullable) NSData *avatarDigest;

// This filename is relative to OWSProfileManager.profileAvatarsDirPath.
@property (nonatomic, nullable) NSString *avatarFileName;

// This should reflect when either:
//
// * The last successful update finished.
// * The current in-flight update began.
//
// This property may be accessed from any thread.
@property (nonatomic, nullable) NSDate *lastUpdateDate;

- (instancetype)init NS_UNAVAILABLE;

@end

#pragma mark -

@implementation UserProfile

- (instancetype)initWithRecipientId:(NSString *)recipientId
{
    self = [super initWithUniqueId:recipientId];

    if (!self) {
        return self;
    }

    OWSAssert(recipientId.length > 0);
    _recipientId = recipientId;

    return self;
}

#pragma mark - NSObject

- (BOOL)isEqual:(UserProfile *)other
{
    return ([other isKindOfClass:[UserProfile class]] && [self.recipientId isEqualToString:other.recipientId] &&
        [self.profileName isEqualToString:other.profileName] && [self.avatarUrl isEqualToString:other.avatarUrl] &&
        [self.avatarDigest isEqual:other.avatarDigest] && [self.avatarFileName isEqualToString:other.avatarFileName]);
}

- (NSUInteger)hash
{
    return self.recipientId.hash ^ self.profileName.hash ^ self.avatarUrl.hash ^ self.avatarDigest.hash
        ^ self.avatarFileName.hash;
}

@end

#pragma mark -

NSString *const kLocalProfileUniqueId = @"kLocalProfileUniqueId";

NSString *const kNSNotificationName_LocalProfileDidChange = @"kNSNotificationName_LocalProfileDidChange";
NSString *const kNSNotificationName_OtherUsersProfileDidChange = @"kNSNotificationName_OtherUsersProfileDidChange";

NSString *const kOWSProfileManager_UserWhitelistCollection = @"kOWSProfileManager_UserWhitelistCollection";
NSString *const kOWSProfileManager_GroupWhitelistCollection = @"kOWSProfileManager_GroupWhitelistCollection";

// TODO:
static const NSInteger kProfileKeyLength = 16;

@interface OWSProfileManager ()

@property (nonatomic, readonly) OWSMessageSender *messageSender;
@property (nonatomic, readonly) YapDatabaseConnection *dbConnection;
@property (nonatomic, readonly) TSNetworkManager *networkManager;

@property (atomic, nullable) UserProfile *localUserProfile;
// This property should only be mutated on the main thread,
@property (nonatomic, nullable) UIImage *localCachedAvatarImage;

// These caches are lazy-populated.  The single point of truth is the database.
//
// These three properties can be accessed on any thread.
@property (atomic, readonly) NSMutableDictionary<NSString *, NSNumber *> *userProfileWhitelistCache;
@property (atomic, readonly) NSMutableDictionary<NSString *, NSNumber *> *groupProfileWhitelistCache;

// This property should only be mutated on the main thread,
@property (nonatomic, readonly) NSCache<NSString *, UIImage *> *otherUsersProfileAvatarImageCache;

// This property should only be mutated on the main thread,
@property (atomic, readonly) NSMutableSet<NSString *> *currentAvatarDownloads;

@end

#pragma mark -

@implementation OWSProfileManager

+ (instancetype)sharedManager
{
    static OWSProfileManager *sharedMyManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedMyManager = [[self alloc] initDefault];
    });
    return sharedMyManager;
}

- (instancetype)initDefault
{
    TSStorageManager *storageManager = [TSStorageManager sharedManager];
    OWSMessageSender *messageSender = [Environment getCurrent].messageSender;
    TSNetworkManager *networkManager = [Environment getCurrent].networkManager;

    return [self initWithStorageManager:storageManager messageSender:messageSender networkManager:networkManager];
}

- (instancetype)initWithStorageManager:(TSStorageManager *)storageManager
                         messageSender:(OWSMessageSender *)messageSender
                        networkManager:(TSNetworkManager *)networkManager
{
    self = [super init];

    if (!self) {
        return self;
    }

    OWSAssert([NSThread isMainThread]);
    OWSAssert(storageManager);
    OWSAssert(messageSender);
    OWSAssert(messageSender);

    _messageSender = messageSender;
    _dbConnection = storageManager.newDatabaseConnection;
    _networkManager = networkManager;

    _userProfileWhitelistCache = [NSMutableDictionary new];
    _groupProfileWhitelistCache = [NSMutableDictionary new];
    _otherUsersProfileAvatarImageCache = [NSCache new];
    _currentAvatarDownloads = [NSMutableSet new];

    OWSSingletonAssert();

    self.localUserProfile = [self getOrBuildUserProfileForRecipientId:kLocalProfileUniqueId];
    OWSAssert(self.localUserProfile);
    if (!self.localUserProfile.profileKey) {
        self.localUserProfile.profileKey = [OWSProfileManager generateLocalProfileKey];
        // Make sure to save on the local db connection for consistency.
        //
        // NOTE: we do an async read/write here to avoid blocking during app launch path.
        [self.dbConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
            [self.localUserProfile saveWithTransaction:transaction];
        }];
    }
    OWSAssert(self.localUserProfile.profileKey.length == kProfileKeyLength);

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)observeNotifications
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

#pragma mark - User Profile Accessor

// This method can be safely called from any thread.
- (UserProfile *)getOrBuildUserProfileForRecipientId:(NSString *)recipientId
{
    OWSAssert(recipientId.length > 0);

    __block UserProfile *instance;
    // Make sure to read on the local db connection for consistency.
    [self.dbConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        instance = [UserProfile fetchObjectWithUniqueID:recipientId transaction:transaction];
    }];

    if (!instance) {
        instance = [[UserProfile alloc] initWithRecipientId:recipientId];
    }

    OWSAssert(instance);

    return instance;
}

// All writes to user profiles should occur on the main thread.
- (void)saveUserProfile:(UserProfile *)userProfile
{
    OWSAssert([NSThread isMainThread]);
    OWSAssert(userProfile);

    // Make sure to save on the local db connection for consistency.
    [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [userProfile saveWithTransaction:transaction];
    }];

    if (userProfile == self.localUserProfile) {
        [[NSNotificationCenter defaultCenter] postNotificationName:kNSNotificationName_LocalProfileDidChange
                                                            object:nil
                                                          userInfo:nil];
    } else {
        [[NSNotificationCenter defaultCenter] postNotificationName:kNSNotificationName_OtherUsersProfileDidChange
                                                            object:nil
                                                          userInfo:nil];
    }
}

#pragma mark - Local Profile Key

+ (NSData *)generateLocalProfileKey
{
    DDLogInfo(@"%@ Generating profile key for local user.", self.tag);
    // TODO:
    DDLogVerbose(@"%@ Profile key generation is not yet implemented.", self.tag);
    return [SecurityUtils generateRandomBytes:kProfileKeyLength];
}

#pragma mark - Local Profile

- (NSData *)localProfileKey
{
    OWSAssert(self.localUserProfile.profileKey.length == kProfileKeyLength);

    return self.localUserProfile.profileKey;
}

- (BOOL)hasLocalProfile
{
    OWSAssert([NSThread isMainThread]);

    return (self.localProfileName.length > 0 || self.localProfileAvatarImage != nil);
}

- (nullable NSString *)localProfileName
{
    OWSAssert([NSThread isMainThread]);

    return self.localUserProfile.profileName;
}

- (nullable UIImage *)localProfileAvatarImage
{
    OWSAssert([NSThread isMainThread]);

    if (!self.localCachedAvatarImage) {
        if (self.localUserProfile.avatarFileName) {
            self.localCachedAvatarImage = [self loadProfileAvatarWithFilename:self.localUserProfile.avatarFileName];
        }
    }

    return self.localCachedAvatarImage;
}

- (void)updateLocalProfileName:(nullable NSString *)profileName
                   avatarImage:(nullable UIImage *)avatarImage
                       success:(void (^)())successBlock
                       failure:(void (^)())failureBlockParameter
{
    OWSAssert([NSThread isMainThread]);
    OWSAssert(successBlock);
    OWSAssert(failureBlockParameter);

    // Ensure that the failure block is called on the main thread.
    void (^failureBlock)() = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            failureBlockParameter();
        });
    };

    // The final steps are to:
    //
    // * Try to update the service.
    // * Update client state on success.
    void (^tryToUpdateService)(NSString *_Nullable, NSData *_Nullable, NSString *_Nullable) = ^(
        NSString *_Nullable avatarUrl, NSData *_Nullable avatarDigest, NSString *_Nullable avatarFileName) {
        [self updateProfileOnService:profileName
            avatarUrl:avatarUrl
            avatarDigest:avatarDigest
            success:^{
                // All reads and writes to user profiles should happen on the main thread.
                dispatch_async(dispatch_get_main_queue(), ^{
                    UserProfile *userProfile = self.localUserProfile;
                    OWSAssert(userProfile);
                    userProfile.profileName = profileName;
                    userProfile.avatarUrl = avatarUrl;
                    userProfile.avatarDigest = avatarDigest;
                    userProfile.avatarFileName = avatarFileName;

                    [self saveUserProfile:userProfile];

                    self.localCachedAvatarImage = avatarImage;

                    successBlock();
                });
            }
            failure:^{
                failureBlock();
            }];
    };

    UserProfile *userProfile = self.localUserProfile;
    OWSAssert(userProfile);

    if (avatarImage) {

        // If we have a new avatar image, we must first:
        //
        // * Encode it to JPEG.
        // * Write it to disk.
        // * Encrypt it
        // * Upload it to asset service
        // * Send asset service info to Signal Service
        if (self.localCachedAvatarImage == avatarImage) {
            OWSAssert(userProfile.avatarUrl.length > 0);
            OWSAssert(userProfile.avatarDigest.length > 0);
            OWSAssert(userProfile.avatarFileName.length > 0);

            DDLogVerbose(@"%@ Updating local profile on service with unchanged avatar.", self.tag);
            // If the avatar hasn't changed, reuse the existing metadata.
            tryToUpdateService(userProfile.avatarUrl, userProfile.avatarDigest, userProfile.avatarFileName);
        } else {
            DDLogVerbose(@"%@ Updating local profile on service with new avatar.", self.tag);
            [self writeAvatarToDisk:avatarImage
                success:^(NSData *data, NSString *fileName) {
                    [self uploadAvatarToService:data
                        fileName:fileName
                        success:^(NSString *avatarUrl, NSData *avatarDigest) {
                            tryToUpdateService(avatarUrl, avatarDigest, fileName);
                        }
                        failure:^{
                            failureBlock();
                        }];
                }
                failure:^{
                    failureBlock();
                }];
        }
    } else {
        DDLogVerbose(@"%@ Updating local profile on service with no avatar.", self.tag);
        tryToUpdateService(nil, nil, nil);
    }
}

- (void)writeAvatarToDisk:(UIImage *)avatar
                  success:(void (^)(NSData *data, NSString *fileName))successBlock
                  failure:(void (^)())failureBlock
{
    OWSAssert(avatar);
    OWSAssert(successBlock);
    OWSAssert(failureBlock);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (avatar) {
            NSData *_Nullable data = UIImageJPEGRepresentation(avatar, 1.f);
            OWSAssert(data);
            if (data) {
                NSString *fileName = [[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"jpg"];
                NSString *filePath = [self.profileAvatarsDirPath stringByAppendingPathComponent:fileName];
                BOOL success = [data writeToFile:filePath atomically:YES];
                OWSAssert(success);
                if (success) {
                    successBlock(data, fileName);
                    return;
                }
            }
        }
        failureBlock();
    });
}

- (NSData *)encryptedAvatarData:(NSData *)plainTextData outDigest:(NSData **)outDigest
{
    DDLogError(@"TODO: Profile encryption scheme not yet settled.");

    // server accepts up to 14 base64 chars for digest
    // 14 <= 4 * ceil(n/3)
    NSUInteger kAvatarDigestByteLength = 9;
    *outDigest = [Cryptography computeSHA256Digest:plainTextData truncatedToBytes:kAvatarDigestByteLength];

    return plainTextData;
}

- (void)uploadAvatarToService:(NSData *)avatarData
                     fileName:(NSString *)fileName // TODO do we need filename?
                      success:(void (^)(NSString *avatarUrl, NSData *avatarDigest))successBlock
                      failure:(void (^)())failureBlock
{
    OWSAssert(avatarData.length > 0);
    OWSAssert(fileName.length > 0);
    OWSAssert(successBlock);
    OWSAssert(failureBlock);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *encryptedAvatarDigest;
        NSData *encryptedAvatarData = [self encryptedAvatarData:avatarData outDigest:&encryptedAvatarDigest];
        OWSAssert(encryptedAvatarData.length > 0);
        OWSAssert(encryptedAvatarDigest.length > 0);

        // See: https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-UsingHTTPPOST.html
        TSProfileAvatarUploadFormRequest *formRequest = [TSProfileAvatarUploadFormRequest new];

        [self.networkManager makeRequest:formRequest
            success:^(NSURLSessionDataTask *task, id formResponseObject) {

                if (![formResponseObject isKindOfClass:[NSDictionary class]]) {
                    OWSProdFail(@"profile_manager_error_avatar_upload_form_invalid_response");
                    failureBlock();
                    return;
                }
                NSDictionary *responseMap = formResponseObject;
                DDLogError(@"responseObject: %@", formResponseObject);

                NSString *formUrl = responseMap[@"url"];
                if (![formUrl isKindOfClass:[NSString class]] || formUrl.length < 1) {
                    OWSProdFail(@"profile_manager_error_avatar_upload_form_invalid_url");
                    failureBlock();
                    return;
                }
                NSString *formAcl = responseMap[@"acl"];
                if (![formAcl isKindOfClass:[NSString class]] || formAcl.length < 1) {
                    OWSProdFail(@"profile_manager_error_avatar_upload_form_invalid_acl");
                    failureBlock();
                    return;
                }
                NSString *formKey = responseMap[@"key"];
                if (![formKey isKindOfClass:[NSString class]] || formKey.length < 1) {
                    OWSProdFail(@"profile_manager_error_avatar_upload_form_invalid_key");
                    failureBlock();
                    return;
                }
                NSString *formPolicy = responseMap[@"policy"];
                if (![formPolicy isKindOfClass:[NSString class]] || formPolicy.length < 1) {
                    OWSProdFail(@"profile_manager_error_avatar_upload_form_invalid_policy");
                    failureBlock();
                    return;
                }
                NSString *formAlgorithm = responseMap[@"algorithm"];
                if (![formAlgorithm isKindOfClass:[NSString class]] || formAlgorithm.length < 1) {
                    OWSProdFail(@"profile_manager_error_avatar_upload_form_invalid_algorithm");
                    failureBlock();
                    return;
                }
                NSString *formCredential = responseMap[@"credential"];
                if (![formCredential isKindOfClass:[NSString class]] || formCredential.length < 1) {
                    OWSProdFail(@"profile_manager_error_avatar_upload_form_invalid_credential");
                    failureBlock();
                    return;
                }
                NSString *formDate = responseMap[@"date"];
                if (![formDate isKindOfClass:[NSString class]] || formDate.length < 1) {
                    OWSProdFail(@"profile_manager_error_avatar_upload_form_invalid_date");
                    failureBlock();
                    return;
                }
                NSString *formSignature = responseMap[@"signature"];
                if (![formSignature isKindOfClass:[NSString class]] || formSignature.length < 1) {
                    OWSProdFail(@"profile_manager_error_avatar_upload_form_invalid_signature");
                    failureBlock();
                    return;
                }

                AFHTTPSessionManager *profileHttpManager =
                    [[OWSSignalService sharedInstance] profileUploadingSessionManagerWithHostname:formUrl];

                // Default acceptable content headers are rejected by AWS
                profileHttpManager.responseSerializer.acceptableContentTypes = nil;

                [profileHttpManager POST:@""
                    parameters:nil
                    constructingBodyWithBlock:^(id<AFMultipartFormData> _Nonnull formData) {
                        NSData * (^formDataForString)(NSString *formString) = ^(NSString *formString) {
                            return [formString dataUsingEncoding:NSUTF8StringEncoding];
                        };

                        // We have to build up the form manually vs. simply passing in a paramaters dict
                        // because AWS is sensitive to the order of the order of the form params (at least
                        // the "key" field must occur early on).
                        // For consistency, all fields are ordered here in a known working order.
                        [formData appendPartWithFormData:formDataForString(formKey) name:@"key"];
                        [formData appendPartWithFormData:formDataForString(formAcl) name:@"acl"];
                        [formData appendPartWithFormData:formDataForString(formAlgorithm) name:@"x-amz-algorithm"];
                        [formData appendPartWithFormData:formDataForString(formCredential) name:@"x-amz-credential"];
                        [formData appendPartWithFormData:formDataForString(formDate) name:@"x-amz-date"];
                        [formData appendPartWithFormData:formDataForString(formPolicy) name:@"policy"];
                        [formData appendPartWithFormData:formDataForString(formSignature) name:@"x-amz-signature"];
                        [formData appendPartWithFormData:formDataForString(OWSMimeTypeApplicationOctetStream)
                                                    name:@"Content-Type"];
                        [formData appendPartWithFormData:encryptedAvatarData name:@"file"];

                        DDLogVerbose(@"%@ constructed body", self.tag);
                    }
                    progress:^(NSProgress *_Nonnull uploadProgress) {
                        DDLogVerbose(
                            @"%@ avatar upload progress: %.2f%%", self.tag, uploadProgress.fractionCompleted * 100);
                    }
                    success:^(NSURLSessionDataTask *_Nonnull uploadTask, id _Nullable responseObject) {
                        OWSAssert([uploadTask.response isKindOfClass:[NSHTTPURLResponse class]]);
                        NSHTTPURLResponse *response = (NSHTTPURLResponse *)uploadTask.response;

                        // We could also construct this URL locally from manager.baseUrl + formKey
                        // but the approach of getting it from the remote provider seems a more
                        // robust way to ensure we've actually created the resource where we
                        // think we have.
                        NSString *avatarURL = response.allHeaderFields[@"Location"];
                        if (avatarURL.length == 0) {
                            OWSProdFail(@"profile_manager_error_avatar_upload_no_location_in_response");
                            failureBlock();
                            return;
                        }

                        DDLogVerbose(@"%@ successfully uploaded avatar url: %@ digest: %@",
                            self.tag,
                            avatarURL,
                            encryptedAvatarDigest);
                        successBlock(avatarURL, encryptedAvatarDigest);
                    }
                    failure:^(NSURLSessionDataTask *_Nullable uploadTask, NSError *_Nonnull error) {
                        DDLogVerbose(@"%@ uploading avatar failed with error: %@", self.tag, error);
                        failureBlock();
                    }];
            }
            failure:^(NSURLSessionDataTask *task, NSError *error) {
                DDLogError(@"%@ Failed to get profile avatar upload form: %@", self.tag, error);
                failureBlock();
            }];
    });
}

// TODO: The exact API & encryption scheme for profiles is not yet settled.
- (void)updateProfileOnService:(nullable NSString *)localProfileName
                     avatarUrl:(nullable NSString *)avatarUrl
                  avatarDigest:(nullable NSData *)avatarDigest
                       success:(void (^)())successBlock
                       failure:(void (^)())failureBlock
{
    OWSAssert(successBlock);
    OWSAssert(failureBlock);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *_Nullable profileNameEncrypted = [self encryptProfileString:localProfileName];

        TSSetProfileRequest *request = [[TSSetProfileRequest alloc] initWithProfileName:profileNameEncrypted
                                                                              avatarUrl:avatarUrl
                                                                           avatarDigest:avatarDigest];

        [self.networkManager makeRequest:request
            success:^(NSURLSessionDataTask *task, id responseObject) {
                successBlock();
            }
            failure:^(NSURLSessionDataTask *task, NSError *error) {
                DDLogError(@"%@ Failed to update profile with error: %@", self.tag, error);
                failureBlock();
            }];
    });
}

#pragma mark - Profile Whitelist

- (void)addUserToProfileWhitelist:(NSString *)recipientId
{
    OWSAssert([NSThread isMainThread]);
    OWSAssert(recipientId.length > 0);

    [self.dbConnection setBool:YES forKey:recipientId inCollection:kOWSProfileManager_UserWhitelistCollection];
    self.userProfileWhitelistCache[recipientId] = @(YES);
}

- (void)addUsersToProfileWhitelist:(NSArray<NSString *> *)recipientIds
{
    OWSAssert([NSThread isMainThread]);
    OWSAssert(recipientIds);

    NSMutableArray<NSString *> *newRecipientIds = [NSMutableArray new];
    for (NSString *recipientId in recipientIds) {
        if (!self.userProfileWhitelistCache[recipientId]) {
            [newRecipientIds addObject:recipientId];
        }
    }

    if (newRecipientIds.count < 1) {
        return;
    }

    [self.dbConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        for (NSString *recipientId in recipientIds) {
            [transaction setObject:@(YES) forKey:recipientId inCollection:kOWSProfileManager_UserWhitelistCollection];
            self.userProfileWhitelistCache[recipientId] = @(YES);
        }
    }];
}

- (BOOL)isUserInProfileWhitelist:(NSString *)recipientId
{
    OWSAssert(recipientId.length > 0);

    NSNumber *_Nullable value = self.userProfileWhitelistCache[recipientId];
    if (value) {
        return [value boolValue];
    }

    value = @([self.dbConnection hasObjectForKey:recipientId inCollection:kOWSProfileManager_UserWhitelistCollection]);
    self.userProfileWhitelistCache[recipientId] = value;
    return [value boolValue];
}

- (void)addGroupIdToProfileWhitelist:(NSData *)groupId
{
    OWSAssert(groupId.length > 0);

    NSString *groupIdKey = [groupId hexadecimalString];
    [self.dbConnection setObject:@(1) forKey:groupIdKey inCollection:kOWSProfileManager_GroupWhitelistCollection];
    self.groupProfileWhitelistCache[groupIdKey] = @(YES);
}

- (void)addThreadToProfileWhitelist:(TSThread *)thread
{
    OWSAssert(thread);

    if (thread.isGroupThread) {
        TSGroupThread *groupThread = (TSGroupThread *)thread;
        NSData *groupId = groupThread.groupModel.groupId;
        [self addGroupIdToProfileWhitelist:groupId];
    } else {
        NSString *recipientId = thread.contactIdentifier;
        [self addUserToProfileWhitelist:recipientId];
    }
}

- (BOOL)isGroupIdInProfileWhitelist:(NSData *)groupId
{
    OWSAssert(groupId.length > 0);

    NSString *groupIdKey = [groupId hexadecimalString];
    NSNumber *_Nullable value = self.groupProfileWhitelistCache[groupIdKey];
    if (value) {
        return [value boolValue];
    }

    value =
        @(nil != [self.dbConnection objectForKey:groupIdKey inCollection:kOWSProfileManager_GroupWhitelistCollection]);
    self.groupProfileWhitelistCache[groupIdKey] = value;
    return [value boolValue];
}

- (BOOL)isThreadInProfileWhitelist:(TSThread *)thread
{
    OWSAssert(thread);

    if (thread.isGroupThread) {
        TSGroupThread *groupThread = (TSGroupThread *)thread;
        NSData *groupId = groupThread.groupModel.groupId;
        return [self isGroupIdInProfileWhitelist:groupId];
    } else {
        NSString *recipientId = thread.contactIdentifier;
        return [self isUserInProfileWhitelist:recipientId];
    }
}

- (void)setContactRecipientIds:(NSArray<NSString *> *)contactRecipientIds
{
    OWSAssert([NSThread isMainThread]);
    OWSAssert(contactRecipientIds);

    // TODO: The persisted whitelist could either be:
    //
    // * Just users manually added to the whitelist.
    // * Also include users auto-added by, for example, being in the user's
    //   contacts or when the user initiates a 1:1 conversation with them, etc.
    [self addUsersToProfileWhitelist:contactRecipientIds];
}

#pragma mark - Other User's Profiles

- (void)setProfileKey:(NSData *)profileKey forRecipientId:(NSString *)recipientId
{
    OWSAssert(profileKey.length == kProfileKeyLength);
    OWSAssert(recipientId.length > 0);
    if (profileKey.length != kProfileKeyLength) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UserProfile *userProfile = [self getOrBuildUserProfileForRecipientId:recipientId];
        OWSAssert(userProfile);
        if (userProfile.profileKey && [userProfile.profileKey isEqual:profileKey]) {
            // Ignore redundant update.
            return;
        }

        userProfile.profileKey = profileKey;

        // Clear profile state.
        userProfile.profileName = nil;
        userProfile.avatarUrl = nil;
        userProfile.avatarDigest = nil;
        userProfile.avatarFileName = nil;

        [self saveUserProfile:userProfile];

        [self refreshProfileForRecipientId:recipientId ignoreThrottling:YES];
    });
}

- (nullable NSData *)profileKeyForRecipientId:(NSString *)recipientId
{
    OWSAssert(recipientId.length > 0);

    UserProfile *userProfile = [self getOrBuildUserProfileForRecipientId:recipientId];
    OWSAssert(userProfile);
    return userProfile.profileKey;
}

- (nullable NSString *)profileNameForRecipientId:(NSString *)recipientId
{
    OWSAssert([NSThread isMainThread]);
    OWSAssert(recipientId.length > 0);

    [self refreshProfileForRecipientId:recipientId];

    UserProfile *userProfile = [self getOrBuildUserProfileForRecipientId:recipientId];
    return userProfile.profileName;
}

- (nullable UIImage *)profileAvatarForRecipientId:(NSString *)recipientId
{
    OWSAssert([NSThread isMainThread]);
    OWSAssert(recipientId.length > 0);

    [self refreshProfileForRecipientId:recipientId];

    UIImage *_Nullable image = [self.otherUsersProfileAvatarImageCache objectForKey:recipientId];
    if (image) {
        return image;
    }

    UserProfile *userProfile = [self getOrBuildUserProfileForRecipientId:recipientId];
    if (userProfile.avatarFileName) {
        image = [self loadProfileAvatarWithFilename:userProfile.avatarFileName];
        if (image) {
            [self.otherUsersProfileAvatarImageCache setObject:image forKey:recipientId];
        }
    } else if (userProfile.avatarUrl) {
        [self downloadAvatarForUserProfile:userProfile];
    }

    return image;
}

- (void)downloadAvatarForUserProfile:(UserProfile *)userProfile
{
    OWSAssert([NSThread isMainThread]);
    OWSAssert(userProfile);

    if (userProfile.profileKey.length < 1 || userProfile.avatarUrl.length < 1) {
        return;
    }

    NSData *profileKeyAtStart = userProfile.profileKey;

    NSURL *url = [NSURL URLWithString:userProfile.avatarUrl];
    if (!url) {
        OWSFail(@"%@ Malformed avatar URL: %@", self.tag, userProfile.avatarUrl);
        return;
    }

    NSString *_Nullable fileExtension = [[[url lastPathComponent] pathExtension] lowercaseString];
    NSSet<NSString *> *validFileExtensions = [NSSet setWithArray:@[
        @"jpg",
        @"jpeg",
        @"png",
        @"gif",
    ]];
    if (![validFileExtensions containsObject:fileExtension]) {
        DDLogWarn(@"Ignoring avatar with invalid file extension: %@", userProfile.avatarUrl);
    }
    NSString *fileName = [[NSUUID UUID].UUIDString stringByAppendingPathExtension:fileExtension];
    NSString *filePath = [self.profileAvatarsDirPath stringByAppendingPathComponent:fileName];

    if ([self.currentAvatarDownloads containsObject:userProfile.recipientId]) {
        // Download already in flight; ignore.
        return;
    }
    [self.currentAvatarDownloads addObject:userProfile.recipientId];

    NSString *tempDirectory = NSTemporaryDirectory();
    NSString *tempFilePath = [tempDirectory stringByAppendingPathComponent:fileName];

    // TODO: Should we use a special configuration as we do in TSNetworkManager?
    // TODO: How does censorship circumvention fit in?
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    AFURLSessionManager *manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    NSURLSessionDownloadTask *downloadTask = [manager downloadTaskWithRequest:request
        progress:nil
        destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
            return [NSURL fileURLWithPath:tempFilePath];
        }
        completionHandler:^(NSURLResponse *response, NSURL *filePathParam, NSError *error) {
            OWSAssert([[NSURL fileURLWithPath:tempFilePath] isEqual:filePathParam]);

            // Ensure disk IO and decryption occurs off the main thread.
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{

                NSData *_Nullable encryptedData = (error ? nil : [NSData dataWithContentsOfFile:tempFilePath]);
                NSData *_Nullable decryptedData =
                    [OWSProfileManager decryptProfileData:encryptedData profileKey:profileKeyAtStart];
                UIImage *_Nullable image = nil;
                if (decryptedData) {
                    // TODO: Verify avatar digest.
                    BOOL success = [decryptedData writeToFile:filePath atomically:YES];
                    if (success) {
                        image = [UIImage imageWithContentsOfFile:filePath];
                    }
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.currentAvatarDownloads removeObject:userProfile.recipientId];

                    UserProfile *currentUserProfile =
                        [self getOrBuildUserProfileForRecipientId:userProfile.recipientId];
                    if (currentUserProfile.profileKey.length < 1
                        || ![currentUserProfile.profileKey isEqual:userProfile.profileKey]) {
                        DDLogWarn(@"%@ Ignoring avatar download for obsolete user profile.", self.tag);
                    } else if (error) {
                        DDLogError(@"%@ avatar download failed: %@", self.tag, error);
                    } else if (!encryptedData) {
                        DDLogError(@"%@ avatar encrypted data could not be read.", self.tag);
                    } else if (!decryptedData) {
                        DDLogError(@"%@ avatar data could not be decrypted.", self.tag);
                    } else if (!image) {
                        DDLogError(@"%@ avatar image could not be loaded: %@", self.tag, error);
                    } else {
                        [self.otherUsersProfileAvatarImageCache setObject:image forKey:userProfile.recipientId];

                        userProfile.avatarFileName = fileName;

                        [self saveUserProfile:userProfile];
                    }
                });
            });
        }];
    [downloadTask resume];
}

- (void)refreshProfileForRecipientId:(NSString *)recipientId
{
    [self refreshProfileForRecipientId:recipientId ignoreThrottling:NO];
}

- (void)refreshProfileForRecipientId:(NSString *)recipientId ignoreThrottling:(BOOL)ignoreThrottling
{
    OWSAssert([NSThread isMainThread]);
    OWSAssert(recipientId.length > 0);

    UserProfile *userProfile = [self getOrBuildUserProfileForRecipientId:recipientId];

    if (!userProfile.profileKey) {
        // There's no point in fetching the profile for a user
        // if we don't have their profile key; we won't be able
        // to decrypt it.
        return;
    }

    // Throttle and debounce the updates.
    const NSTimeInterval kMaxRefreshFrequency = 5 * kMinuteInterval;
    if (userProfile.lastUpdateDate && fabs([userProfile.lastUpdateDate timeIntervalSinceNow]) < kMaxRefreshFrequency) {
        // This profile was updated recently or already has an update in flight.
        return;
    }

    userProfile.lastUpdateDate = [NSDate new];

    [self saveUserProfile:userProfile];

    [ProfileFetcherJob runWithRecipientId:recipientId
                           networkManager:self.networkManager
                         ignoreThrottling:ignoreThrottling];
}

- (void)updateProfileForRecipientId:(NSString *)recipientId
               profileNameEncrypted:(NSData *_Nullable)profileNameEncrypted
                      avatarUrlData:(NSData *_Nullable)avatarUrlData
                       avatarDigest:(NSData *_Nullable)avatarDigestParam
{
    OWSAssert(recipientId.length > 0);

    // Ensure decryption, etc. off main thread.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{

        UserProfile *userProfile = [self getOrBuildUserProfileForRecipientId:recipientId];
        if (!userProfile.profileKey) {
            return;
        }

        NSString *_Nullable profileName =
            [self decryptProfileString:profileNameEncrypted profileKey:userProfile.profileKey];
        NSString *_Nullable avatarUrl
            = (avatarUrlData ? [[NSString alloc] initWithData:avatarUrlData encoding:NSUTF8StringEncoding] : nil);
        NSData *_Nullable avatarDigest = avatarDigestParam;

        if (!avatarUrl || !avatarDigest) {
            // If either avatar url or digest is missing, skip both.
            avatarUrl = nil;
            avatarDigest = nil;
        }

        BOOL isAvatarSame = ([self isNullableStringEqual:userProfile.avatarUrl toString:avatarUrl] &&
            [self isNullableDataEqual:userProfile.avatarDigest toData:avatarDigest]);

        dispatch_async(dispatch_get_main_queue(), ^{
            userProfile.profileName = profileName;
            userProfile.avatarUrl = avatarUrl;
            userProfile.avatarDigest = avatarDigest;

            if (!isAvatarSame) {
                // Evacuate avatar image cache.
                [self.otherUsersProfileAvatarImageCache removeObjectForKey:recipientId];

                if (avatarUrl) {
                    [self downloadAvatarForUserProfile:userProfile];
                }
            }

            userProfile.lastUpdateDate = [NSDate new];

            [self saveUserProfile:userProfile];
        });
    });
}

- (BOOL)isNullableDataEqual:(NSData *_Nullable)left toData:(NSData *_Nullable)right
{
    if (left == nil && right == nil) {
        return YES;
    } else if (left == nil || right == nil) {
        return YES;
    } else {
        return [left isEqual:right];
    }
}

- (BOOL)isNullableStringEqual:(NSString *_Nullable)left toString:(NSString *_Nullable)right
{
    if (left == nil && right == nil) {
        return YES;
    } else if (left == nil || right == nil) {
        return YES;
    } else {
        return [left isEqualToString:right];
    }
}

#pragma mark - Profile Encryption

+ (NSData *_Nullable)decryptProfileData:(NSData *_Nullable)encryptedData profileKey:(NSData *)profileKey
{
    OWSAssert(profileKey.length == kProfileKeyLength);

    if (!encryptedData) {
        return nil;
    }

    // TODO: Decrypt.  For now, return the input.
    return encryptedData;
}

+ (NSString *_Nullable)decryptProfileString:(NSData *_Nullable)encryptedData profileKey:(NSData *)profileKey
{
    OWSAssert(profileKey.length == kProfileKeyLength);

    NSData *_Nullable decryptedData = [self decryptProfileData:encryptedData profileKey:profileKey];

    if (decryptedData) {
        return [[NSString alloc] initWithData:decryptedData encoding:NSUTF8StringEncoding];
    } else {
        return nil;
    }
}

+ (NSData *_Nullable)encryptProfileData:(NSData *_Nullable)data profileKey:(NSData *)profileKey
{
    OWSAssert(profileKey.length == kProfileKeyLength);

    if (!data) {
        return nil;
    }

    // TODO: Encrypt.  For now, return the input.
    return data;
}

+ (NSData *_Nullable)encryptProfileString:(NSString *_Nullable)value profileKey:(NSData *)profileKey
{
    OWSAssert(profileKey.length == kProfileKeyLength);

    if (value) {
        NSData *_Nullable data = [value dataUsingEncoding:NSUTF8StringEncoding];
        if (data) {
            NSData *_Nullable encryptedData = [self encryptProfileData:data profileKey:profileKey];
            return encryptedData;
        }
    }

    return nil;
}

- (NSData *_Nullable)decryptProfileData:(NSData *_Nullable)encryptedData profileKey:(NSData *)profileKey
{
    return [OWSProfileManager decryptProfileData:encryptedData profileKey:profileKey];
}

- (NSString *_Nullable)decryptProfileString:(NSData *_Nullable)encryptedData profileKey:(NSData *)profileKey
{
    return [OWSProfileManager decryptProfileString:encryptedData profileKey:profileKey];
}

- (NSData *_Nullable)encryptProfileData:(NSData *_Nullable)data
{
    return [OWSProfileManager encryptProfileData:data profileKey:self.localProfileKey];
}

- (NSData *_Nullable)encryptProfileString:(NSString *_Nullable)value
{
    return [OWSProfileManager encryptProfileString:value profileKey:self.localProfileKey];
}

#pragma mark - Avatar Disk Cache

- (nullable UIImage *)loadProfileAvatarWithFilename:(NSString *)fileName
{
    OWSAssert(fileName.length > 0);

    NSString *filePath = [self.profileAvatarsDirPath stringByAppendingPathComponent:fileName];
    UIImage *_Nullable image = [UIImage imageWithContentsOfFile:filePath];
    return image;
}

- (NSString *)profileAvatarsDirPath
{
    static NSString *profileAvatarsDirPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *documentsPath =
            [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        profileAvatarsDirPath = [documentsPath stringByAppendingPathComponent:@"ProfileAvatars"];

        BOOL isDirectory;
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:profileAvatarsDirPath isDirectory:&isDirectory];
        if (exists) {
            OWSAssert(isDirectory);

            DDLogInfo(@"Profile avatars directory already exists");
        } else {
            NSError *error = nil;
            [[NSFileManager defaultManager] createDirectoryAtPath:profileAvatarsDirPath
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&error];
            if (error) {
                DDLogError(@"Failed to create profile avatars directory: %@", error);
            }
        }
    });
    return profileAvatarsDirPath;
}

// TODO: We may want to clean up this directory in the "orphan cleanup" logic.

- (void)resetProfileStorage
{
    OWSAssert([NSThread isMainThread]);

    NSError *error;
    [[NSFileManager defaultManager] removeItemAtPath:[self profileAvatarsDirPath] error:&error];
    if (error) {
        DDLogError(@"Failed to delete database: %@", error.description);
    }
}

#pragma mark - Notifications

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    OWSAssert([NSThread isMainThread]);

    @synchronized(self)
    {
        // TODO: Sync if necessary.
    }
}

#pragma mark - Logging

+ (NSString *)tag
{
    return [NSString stringWithFormat:@"[%@]", self.class];
}

- (NSString *)tag
{
    return self.class.tag;
}

@end

NS_ASSUME_NONNULL_END
