// Copyright 2016-2017 Cisco Systems Inc
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import UIKit
import ObjectMapper
import SparkSDKEncryptionKit
import Alamofire
import SwiftyJSON


public class ActivityClient {
    
    /// Callback when receive Message.
    ///
    /// - since: 1.4.0
    public var onMessageActivity:((MessageActivity) -> Void)?
    
    /// Callback when receive acknowledge activity.
    ///
    /// - since: 1.4.0
    public var onTypingActivity:((TypingActivity) -> Void)?
    
    /// Callback when delete Message.
    ///
    /// - since: 1.4.0
    public var onFlagActivity:((FlagActivity) -> Void)?
    
    
    let authenticator: Authenticator
    
    /// Lists all messages in a room by room Id.
    /// If present, it includes the associated media content attachment for each message.
    /// The list sorts the messages in descending order by creation date.
    ///
    /// - parameter conversationId: The identifier of the conversation.
    /// - parameter sinceDate: the activities published date is after this date, format in "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
    /// - parameter midDate: The activities published date is before or after this date. At most limit/2 activities activities before and limit/2 activities after the date will be included, format in "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
    /// - parameter maxDate: the activities published date is before this date, format in "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
    /// - parameter limit:  Maximum number of activities return. Default is 6.
    /// - parameter personRefresh: (experimental)control if the person detail in activity need to be refreshed to latest. If person detail got      refreshed, person.id will be in UUID format even if original one is email. Default is false.
    /// - parameter lastActivityFirst: Sort order for the activities. Default is true.
    /// - parameter queue: If not nil, the queue on which the completion handler is dispatched. Otherwise, the handler is dispatched on the application's main thread.
    /// - parameter completionHandler: A closure to be executed once the request has finished.
    /// - returns: Void
    /// - since: 1.4.0
    public func listMessageActivities(conversationId: String,
                                      sinceDate: String? = nil,
                                      maxDate: String? = nil,
                                      midDate: String? = nil,
                                      limit: Int? = nil,
                                      personRefresh: Bool? = false,
                                      lastActivityFirst: Bool? = true,
                                      queue: DispatchQueue? = nil,
                                      completionHandler: @escaping (ServiceResponse<[MessageActivity]>) -> Void)
    {
        let query = RequestParameter([
            "conversationId": conversationId,
            "sinceDate": sinceDate,
            "maxDate": maxDate,
            "midDate": midDate,
            "limit": limit,
            "personRefresh": personRefresh,
            "lastActivityFirst": lastActivityFirst,
            ])
        
        let request = activityServiceBuilder().path("activities")
            .keyPath("items")
            .method(.get)
            .query(query)
            .queue(queue)
            .build()
        
        if self.encryptKeyReadyFor(conversationId){
            let roomResource = self.roomResourceList.filter({$0.conversationId == conversationId}).first
            let listOperation = ListActivityOperation(conversationId: conversationId,
                                                      listRequest: request,
                                                      keyMaterial: roomResource?.keyMaterial,
                                                      completionHandler: completionHandler)
            self.executeOperationQueue.addOperation(listOperation)
            return
        }else{
            if (self.roomResourceList.filter({$0.conversationId == conversationId}).first == nil){
                let roomSource = AcitivityRoomResourceModel(conversationId: conversationId)
                self.roomResourceList.append(roomSource)
            }
            let listOperation = ListActivityOperation(conversationId: conversationId,
                                                      listRequest: request,
                                                      completionHandler: completionHandler)
            self.pendingListOperationList.append(listOperation)
            if(!self.isClientReady){
                self.requestClientInfo()
            }else{
                self.requestEncryptionUrlFor(conversationId)
            }
        }
    }
    
    /// Detail of one messate activity.
    ///
    /// - parameter activityID: The identifier of the activity.
    /// - parameter queue: If not nil, the queue on which the completion handler is dispatched. Otherwise, the handler is dispatched on the application's main thread.
    /// - parameter completionHandler: A closure to be executed once the request has finished.
    /// - returns: Void
    /// - since: 1.4.0
    public func messageActivityDetail(activityID: String,
                                      queue: DispatchQueue? = nil,
                                      completionHandler: @escaping (ServiceResponse<MessageActivity>) -> Void)
    {
        let request = activityServiceBuilder().path("activities")
            .method(.get)
            .path(activityID)
            .queue(queue)
            .build()
        request.responseObject { (response : ServiceResponse<MessageActivity>) in
            switch response.result{
            case .success(let message):
                if self.encryptKeyReadyFor(message.conversationId!){
                    self.decryptMessage(message)
                    completionHandler(response)
                }else{
                    self.pendingDetailMessageList[message.activityId!] = completionHandler
                    self.receiveNewMessageActivity(messageActivity: message)
                }
                break
            case .failure(_):
                completionHandler(response)
                break
            }
        }
    }
    
    /// Posts a plain text message, to a conversation by conversation Id.
    ///
    /// - parameter conversation: The identifier of the conversation where the message is to be posted.
    /// - parameter content: The plain text message to be posted to the room.
    /// - parameter medtions: The mention items to be posted to the room.
    /// - parameter files: local file pathes to be uploaded to the room.
    /// - parameter queue: If not nil, the queue on which the completion handler is dispatched. Otherwise, the handler is dispatched on the application's main thread.
    /// - parameter completionHandler: A closure to be executed once the request has finished.
    /// - returns: Void
    /// - since: 1.4.0
    public func postMessage(conversationId: String,
                            content: String?=nil,
                            mentions: [ActivityMentionModel]? = nil,
                            files: [FileObjectModel]? = nil,
                            queue: DispatchQueue? = nil,
                            uploadProgressHandler: ((FileObjectModel, Double)->Void)? = nil,
                            completionHandler: @escaping (ServiceResponse<MessageActivity>) -> Void)
    {
        
        let messageActivity = MessageActivity()
        messageActivity.conversationId = conversationId
        messageActivity.plainText = content
        
        if let mentionItems = mentions {
            messageActivity.mentionItems = mentionItems
        }
        
        if let fileList = files {
            messageActivity.action = MessageAction.share
            messageActivity.files = fileList
            if self.readyToShareFor(conversationId){
                let roomResource = self.roomResourceList.filter({$0.conversationId == conversationId}).first
                messageActivity.encryptionKeyUrl = roomResource?.encryptionUrl
                let msgPostOperation = PostMessageOperation(authenticator:self.authenticator,
                                                            messageActivity: messageActivity,
                                                            keyMaterial:  roomResource?.keyMaterial,
                                                            spaceUrl: roomResource?.spaceUrl,
                                                            queue:queue,
                                                            uploadingProgressHandler : uploadProgressHandler,
                                                            completionHandler: completionHandler)
                SDKLogger.shared.info("Activity Added POSTing Queue...")
                self.executeOperationQueue.addOperation(msgPostOperation)
                return
            }else if self.encryptKeyReadyFor(conversationId){
                let roomResource = self.roomResourceList.filter({$0.conversationId == conversationId}).first
                messageActivity.encryptionKeyUrl = roomResource?.encryptionUrl
                let msgPostOperation = PostMessageOperation(authenticator:self.authenticator,
                                                            messageActivity: messageActivity,
                                                            keyMaterial:  roomResource?.keyMaterial,
                                                            queue:queue,
                                                            uploadingProgressHandler : uploadProgressHandler,
                                                            completionHandler: completionHandler)
                SDKLogger.shared.info("Activity Added POSTing Queue...")
                self.pendingOperationList.append(msgPostOperation)
                self.requestSpaceUrl(convasationId: conversationId)
                return
            }
        }else{
            messageActivity.action = MessageAction.post
            if self.encryptKeyReadyFor(conversationId){
                let roomResource = self.roomResourceList.filter({$0.conversationId == conversationId}).first
                messageActivity.encryptionKeyUrl = roomResource?.encryptionUrl
                let msgPostOperation = PostMessageOperation(authenticator:self.authenticator,
                                                            messageActivity: messageActivity,
                                                            keyMaterial:roomResource?.keyMaterial,
                                                            queue:queue,
                                                            completionHandler: completionHandler)
                SDKLogger.shared.info("Activity Added POSTing Queue...")
                self.executeOperationQueue.addOperation(msgPostOperation)
                return
            }
        }
        
        if (self.roomResourceList.filter({$0.conversationId == conversationId}).first == nil){
            let roomSource = AcitivityRoomResourceModel(conversationId: conversationId)
            self.roomResourceList.append(roomSource)
        }
        let msgPostOperation = PostMessageOperation(authenticator:self.authenticator,
                                                    messageActivity: messageActivity,
                                                    queue:queue,
                                                    uploadingProgressHandler : uploadProgressHandler,
                                                    completionHandler: completionHandler)
        SDKLogger.shared.info("Activity Added POSTing Queue...")
        self.pendingOperationList.append(msgPostOperation)
        if(!self.isClientReady){
            self.requestClientInfo()
        }else{
            self.requestEncryptionUrlFor(conversationId)
            
        }
    }
    
    /// Deletes a message, to a conversation by conversation Id.
    ///
    /// - parameter conversation: The identifier of the conversation where the message is to be posted.
    /// - parameter activityId: The messageId to be deleted in the room.
    /// - parameter queue: If not nil, the queue on which the completion handler is dispatched. Otherwise, the handler is dispatched on the application's main thread.
    /// - parameter completionHandler: A closure to be executed once the request has finished.
    /// - returns: Void
    /// - since: 1.4.0
    public func deleteMessage(conversationId: String,
                              messageActivityId: String,
                              queue: DispatchQueue? = nil,
                              completionHandler: @escaping (ServiceResponse<MessageActivity>) -> Void)
    {
        
        let messageActivity = MessageActivity()
        messageActivity.conversationId = conversationId
        messageActivity.activityId = messageActivityId
        messageActivity.action = MessageAction.delete
        let msgPostOperation = PostMessageOperation(authenticator:self.authenticator, messageActivity: messageActivity,queue:queue, completionHandler: completionHandler)
        self.executeOperationQueue.addOperation(msgPostOperation)
    }
    
    /// Post a message read indicator, to a conversation by conversation Id.
    ///
    /// - parameter conversation: The identifier of the conversation where the indicator is to be posted.
    /// - parameter activityId: The activity that is read .
    /// - parameter queue: If not nil, the queue on which the completion handler is dispatched. Otherwise, the handler is dispatched on the application's main thread.
    /// - parameter completionHandler: A closure to be executed once the request has finished.
    /// - returns: Void
    /// - since: 1.4.0
    public func read(conversationId: String,
                     massageActivityId: String,
                     queue: DispatchQueue? = nil,
                     completionHandler: @escaping (ServiceResponse<MessageActivity>) -> Void)
    {
        let messageActivity = MessageActivity()
        messageActivity.conversationId = conversationId
        messageActivity.activityId = massageActivityId
        messageActivity.action = MessageAction.acknowledge
        let msgPostOperation = PostMessageOperation(authenticator:self.authenticator, messageActivity: messageActivity,queue:queue, completionHandler: completionHandler)
        self.executeOperationQueue.addOperation(msgPostOperation)
    }
    
    /// Post a typing indicator, to a conversation by conversation Id.
    ///
    /// - parameter conversation: The identifier of the conversation where the indicator is to be posted.
    /// - parameter queue: If not nil, the queue on which the completion handler is dispatched. Otherwise, the handler is dispatched on the application's main thread.
    /// - parameter completionHandler: A closure to be executed once the request has finished.
    /// - returns: Void
    /// - since: 1.4.0
    public func startTyping(conversationId: String,
                            queue: DispatchQueue? = nil,
                            completionHandler: @escaping (ServiceResponse<Any>) -> Void) -> Void
    {
        let body = RequestParameter([
            "eventType": "status.start_typing",
            "conversationId" : conversationId
            ])
        let request = activityServiceBuilder().path("status/typing")
            .method(.post)
            .body(body)
            .queue(queue)
            .build()
        request.responseJSON(completionHandler)
    }
    
    /// Post a stop-typing indicator, to a conversation by conversation Id.
    ///
    /// - parameter conversation: The identifier of the conversation where the indicator is to be posted.
    /// - parameter queue: If not nil, the queue on which the completion handler is dispatched. Otherwise, the handler is dispatched on the application's main thread.
    /// - parameter completionHandler: A closure to be executed once the request has finished.
    /// - returns: Void
    /// - since: 1.4.0
    public func stopTyping(conversationId: String,
                           queue: DispatchQueue? = nil,
                           completionHandler: @escaping (ServiceResponse<Any>) -> Void) -> Void
    {
        let body = RequestParameter([
            "eventType": "status.stop_typing",
            "conversationId" : conversationId
            ])
        let request = activityServiceBuilder().path("status/typing")
            .method(.post)
            .body(body)
            .queue(queue)
            .build()
        request.responseJSON(completionHandler)
    }
    
    /// Post flag an activity action, to a activity by activity url.
    ///
    /// - parameter queue: If not nil, the queue on which the completion handler is dispatched. Otherwise, the handler is dispatched on the application's main thread.
    /// - parameter completionHandler: A closure to be executed once the request has finished.
    /// - returns: Void
    /// - since: 1.4.0
    public func flag(flagItemUrl: String,
                     queue: DispatchQueue? = nil,
                     completionHandler: @escaping (ServiceResponse<FlagActivity>) -> Void) -> Void
    {
        let body = RequestParameter([
            "flag-item": flagItemUrl,
            "state": "flagged"
            ])
        
        let request = flagRequestBuilder()
            .method(.post)
            .body(body)
            .queue(queue)
            .build()
        request.responseObject(completionHandler)
    }
    
    /// Post  unflag an activity action, to a flag tem by flagId.
    ///
    /// - parameter queue: If not nil, the queue on which the completion handler is dispatched. Otherwise, the handler is dispatched on the application's main thread.
    /// - parameter completionHandler: A closure to be executed once the request has finished.
    /// - returns: Void
    /// - since: 1.4.0
    public func unFlag(flagItemId: String,
                       queue: DispatchQueue? = nil,
                       completionHandler: @escaping (ServiceResponse<Any>) -> Void) -> Void
    {
        let request = flagRequestBuilder().path(flagItemId)
            .method(.delete)
            .queue(queue)
            .build()
        request.responseJSON(completionHandler)
    }
    
    /// Download a file object, download both file body / thumbnail if exist.
    ///
    /// - parameter conversation: The identifier of the conversation where the fike is fetched.
    /// - parameter file: file object.
    /// - parameter downLoadProgressHandler: the download progress indicator.
    /// - parameter completionHandler: downloaded file local address wiil be stored in "file.localFileUrl"
    /// - returns: Void
    /// - since: 1.4.0
    public func downLoadFile(conversationId: String,
                             file: FileObjectModel,
                             downLoadProgressHandler: ((Double)->Void)? = nil,
                             completionHandler: @escaping (FileObjectModel,FileDownLoadState) -> Void){
        
        let roomResource = self.roomResourceList.filter({$0.conversationId == conversationId}).first
        let downLoadOperation = DownLoadFileOperation(token: accessTokenStr,
                                                      uuid: self.uuid,
                                                      fileModel: file,
                                                      keyMatiarial: (roomResource?.keyMaterial)!,
                                                      progressHandler: downLoadProgressHandler,
                                                      completionHandler:completionHandler)
        SDKLogger.shared.info("File Added Downloading Queue...")
        self.executeOperationQueue.addOperation(downLoadOperation)
    }
    
    /// Download a file object, download both file thumbnail only if exist.
    ///
    /// - parameter conversation: The identifier of the conversation where the fike is fetched.
    /// - parameter file: file object.
    /// - parameter downLoadProgressHandler: the download progress indicator.
    /// - parameter completionHandler: downloaded file local address wiil be stored in "file.localFileUrl"
    /// - returns: Void
    /// - since: 1.4.0
    public func downLoadThumbNail(conversationId: String,
                                  file: FileObjectModel,
                                  downLoadProgressHandler: ((Double)->Void)? = nil,
                                  completionHandler: @escaping (FileObjectModel,FileDownLoadState) -> Void){
        
        let roomResource = self.roomResourceList.filter({$0.conversationId == conversationId}).first
        let downLoadOperation = DownLoadFileOperation(token: accessTokenStr,
                                                      uuid: self.uuid,
                                                      fileModel: file,
                                                      keyMatiarial: (roomResource?.keyMaterial)!,
                                                      downLoadType: .ThumbOnly,
                                                      progressHandler: downLoadProgressHandler,
                                                      completionHandler:completionHandler)
        SDKLogger.shared.info("File Added Downloading Queue...")
        self.executeOperationQueue.addOperation(downLoadOperation)
    }
    
    /// Download a file object, download both file body only if exist.
    ///
    /// - parameter conversation: The identifier of the conversation where the fike is fetched.
    /// - parameter file: file object.
    /// - parameter downLoadProgressHandler: the download progress indicator.
    /// - parameter completionHandler: downloaded file local address wiil be stored in "file.localFileUrl"
    /// - returns: Void
    /// - since: 1.4.0
    public func downLoadFileBody(conversationId: String,
                                 file: FileObjectModel,
                                 downLoadProgressHandler: ((Double)->Void)? = nil,
                                 completionHandler: @escaping (FileObjectModel,FileDownLoadState) -> Void){
        
        let roomResource = self.roomResourceList.filter({$0.conversationId == conversationId}).first
        let downLoadOperation = DownLoadFileOperation(token: accessTokenStr,
                                                      uuid: self.uuid,
                                                      fileModel: file,
                                                      keyMatiarial: (roomResource?.keyMaterial)!,
                                                      downLoadType: .BodyOnly,
                                                      progressHandler: downLoadProgressHandler,
                                                      completionHandler:completionHandler)
        SDKLogger.shared.info("File Added Downloading Queue...")
        self.executeOperationQueue.addOperation(downLoadOperation)
    }
    
    
    
    
    // MARK: Encryption Feature Variables
    /// ActivityClient Errors
    enum ActivityError: Error {
        case clientInfoFetchFail
        case ephemaralKeyFetchFail
        case kmsInfoFetchFail
        case keyMaterialFetchFail
        case encryptionUrlFetchFail
        case spaceUrlFetchFail
    }
    private let kmsMessageServerUri = ServiceRequest.KMS_SERVER_ADDRESS + "/kms/messages"
    private var roomResourceList : [AcitivityRoomResourceModel] = [AcitivityRoomResourceModel]()
    private var kmsRequestList : [KmsRequest] = [KmsRequest]()
    private var noEncryptionConvasationList : [String] = [String]()
    private var receivedActivityList : [MessageActivity] = [MessageActivity]()
    private var pendingOperationList: [PostMessageOperation] = [PostMessageOperation]()
    private var pendingListOperationList: [ListActivityOperation] = [ListActivityOperation]()
    private var pendingDetailMessageList: [String: (ServiceResponse<MessageActivity>) -> Void] = [String: (ServiceResponse<MessageActivity>) -> Void]()
    private var executeOperationQueue: OperationQueue = OperationQueue()
    
    var deviceUrl : URL
    var uuid: String = ""
    var accessTokenStr = ""
    var userId : String?
    private var kmsCluster: String?
    private var rsaPublicKey: String?
    private var ephemeralKeyRequest: KmsEphemeralKeyRequest?
    private var ephemeralKeyFetched: Bool = false
    private var ephemeralKeyStr: String = ""
    
    init(authenticator: Authenticator, diviceUrl: URL) {
        self.authenticator = authenticator
        self.deviceUrl = diviceUrl
        self.uuid = UUID().uuidString
        self.executeOperationQueue.maxConcurrentOperationCount = 1
    }
    
    // MARK: Encryption Feature Functions
    public func receiveNewMessageActivity( messageActivity: MessageActivity){
        if(messageActivity.encryptionKeyUrl != nil){
            self.receivedActivityList.append(messageActivity)
            if self.roomResourceList.filter({$0.conversationId == messageActivity.conversationId}).first == nil{
                let roomModel = AcitivityRoomResourceModel(conversationId: messageActivity.conversationId!)
                roomModel.encryptionUrl = messageActivity.encryptionKeyUrl
                self.roomResourceList.append(roomModel)
            }
            if(!self.isClientReady){
                self.requestClientInfo()
            }else if(self.encryptKeyReadyFor(messageActivity.conversationId!)){
                self.processReceivedMessage(messageActivity)
            }else{
                self.requestKeyMaterial(messageActivity.encryptionKeyUrl!)
            }
        }else{
            messageActivity.markDownString()
            if let comHandler = self.pendingDetailMessageList[messageActivity.activityId!]{
                let result = Result<MessageActivity>.success(messageActivity)
                comHandler(ServiceResponse.init(nil, result))
                self.pendingDetailMessageList.removeValue(forKey: messageActivity.activityId!)
            }else{
                self.onMessageActivity?(messageActivity)
            }
        }
    }
    
    public func receiveKmsMessage( _ kmsMessageModel: KmsMessageModel){
        if(self.ephemeralKeyRequest == nil && self.ephemeralKeyFetched){
            /// receive key material
            do{
                let responseStr = kmsMessageModel.kmsMessageStrs?.first!
                let kmsMessageData = try CjoseWrapper.content(fromCiphertext: responseStr, key: self.ephemeralKeyStr)
                let kmsMessageJson = JSON(data: kmsMessageData)
                
                if let dict = kmsMessageJson["key"].object as? [String:Any]{
                    if let keyMaterial = JSON(dict["jwk"]!).rawString(),
                        let keyUri = JSON(dict["uri"]!).rawString(){
                        if let room = self.roomResourceList.filter({$0.encryptionUrl == keyUri}).first{
                            room.keyMaterial = keyMaterial
                            self.processPendingMessageActivities(keyUri)
                        }
                        _ = self.kmsRequestList.removeObject(equality: { $0.uri == keyUri})
                    }
                }else if let conversationId = self.noEncryptionConvasationList.popLast(),
                    let keys = kmsMessageJson["keys"].object as? [[String : Any]]{
                    for keyDict in keys{
                        let key : KmsKey = try KmsKey(from: keyDict)
                        let encriptionUrl = key.uri
                        let keyMaterial = key.jwk
                        if let room = self.roomResourceList.filter({$0.conversationId == conversationId}).first{
                            room.keyMaterial = keyMaterial
                            room.encryptionUrl = encriptionUrl
                            self.processFilePostingMessageActivitiesWith(conversationId)
                        }
                    }
                }
            }catch let error as NSError {
                SDKLogger.shared.debug("Error - Receive KmsMessage: \(error.debugDescription)")
            }
        }else{
            /// receive ephemaral key message
            do{
                let responseStr = kmsMessageModel.kmsMessageStrs?.first!
                let kmsresponse = try KmsEphemeralKeyResponse(responseMessage: responseStr, request: self.ephemeralKeyRequest!)
                self.ephemeralKeyStr = kmsresponse.jwkEphemeralKey
                self.ephemeralKeyFetched = true
                self.ephemeralKeyRequest = nil
                for roomResouce in self.roomResourceList{
                    if let encrptionUrl = roomResouce.encryptionUrl{
                        if let _ = roomResouce.keyMaterial{
                            self.processPendingMessageActivities(encrptionUrl)
                        }else{
                            self.requestKeyMaterial(encrptionUrl)
                        }
                    }else{
                        self.requestEncryptionUrlFor(roomResouce.conversationId)
                    }
                }
            }catch let error as NSError {
                self.ephemeralKeyRequest = nil
                SDKLogger.shared.debug("Error - Receive EpheMeralKMS: \(error.debugDescription)")
            }
        }
    }
    
    private func processReceivedMessage(_ messageActivity: MessageActivity){
        guard let acitivityKeyMaterial = self.roomResourceList.filter({$0.encryptionUrl == messageActivity.encryptionKeyUrl!}).first?.keyMaterial else{
            return
        }
        _ = self.receivedActivityList.removeObject(equality: { $0.activityId == messageActivity.activityId })
        do {
            guard let chiperText = messageActivity.plainText
                else{
                    return;
            }
            if(chiperText != ""){
                let plainTextData = try CjoseWrapper.content(fromCiphertext: chiperText, key: acitivityKeyMaterial)
                let clearText = NSString(data:plainTextData ,encoding: String.Encoding.utf8.rawValue)
                messageActivity.plainText = clearText! as String
                messageActivity.markDownString()
            }
            if let files = messageActivity.files{
                for file in files{
                    if let displayname = file.displayName,
                        let scr = file.scr
                    {
                        let nameData = try CjoseWrapper.content(fromCiphertext: displayname, key: acitivityKeyMaterial)
                        let clearName = NSString(data:nameData ,encoding: String.Encoding.utf8.rawValue)! as String
                        let srcData = try CjoseWrapper.content(fromCiphertext: scr, key: acitivityKeyMaterial)
                        let clearSrc = NSString(data:srcData ,encoding: String.Encoding.utf8.rawValue)! as String
                        if let image = file.image{
                            let imageSrcData = try CjoseWrapper.content(fromCiphertext: image.scr, key: acitivityKeyMaterial)
                            let imageClearSrc = NSString(data:imageSrcData ,encoding: String.Encoding.utf8.rawValue)! as String
                            image.scr = imageClearSrc
                        }
                        file.displayName = clearName
                        file.scr = clearSrc
                    }
                }
                messageActivity.files = files
            }
            if let comHandler = self.pendingDetailMessageList[messageActivity.activityId!]{
                let result = Result<MessageActivity>.success(messageActivity)
                comHandler(ServiceResponse.init(nil, result))
                self.pendingDetailMessageList.removeValue(forKey: messageActivity.activityId!)
            }else{
                self.onMessageActivity?(messageActivity)
            }
        }catch let error as NSError {
            SDKLogger.shared.debug("Process Activity Error - \(error.description)")
        }
    }
    
    private func decryptMessage(_ messageActivity: MessageActivity){
        guard let acitivityKeyMaterial = self.roomResourceList.filter({$0.encryptionUrl == messageActivity.encryptionKeyUrl!}).first?.keyMaterial else{
            return
        }
        _ = self.receivedActivityList.removeObject(equality: { $0.activityId == messageActivity.activityId })
        do {
            guard let chiperText = messageActivity.plainText
                else{
                    return;
            }
            if(chiperText != ""){
                let plainTextData = try CjoseWrapper.content(fromCiphertext: chiperText, key: acitivityKeyMaterial)
                let clearText = NSString(data:plainTextData ,encoding: String.Encoding.utf8.rawValue)
                messageActivity.plainText = clearText! as String
                messageActivity.markDownString()
            }
            if let files = messageActivity.files{
                for file in files{
                    if let displayname = file.displayName,
                        let scr = file.scr
                    {
                        let nameData = try CjoseWrapper.content(fromCiphertext: displayname, key: acitivityKeyMaterial)
                        let clearName = NSString(data:nameData ,encoding: String.Encoding.utf8.rawValue)! as String
                        let srcData = try CjoseWrapper.content(fromCiphertext: scr, key: acitivityKeyMaterial)
                        let clearSrc = NSString(data:srcData ,encoding: String.Encoding.utf8.rawValue)! as String
                        if let image = file.image{
                            let imageSrcData = try CjoseWrapper.content(fromCiphertext: image.scr, key: acitivityKeyMaterial)
                            let imageClearSrc = NSString(data:imageSrcData ,encoding: String.Encoding.utf8.rawValue)! as String
                            image.scr = imageClearSrc
                        }
                        file.displayName = clearName
                        file.scr = clearSrc
                    }
                }
                messageActivity.files = files
            }
        }catch let error as NSError {
            SDKLogger.shared.debug("Process Activity Error - \(error.description)")
        }
    }
    
    
    /// Process received | posting pending activities
    private func processPendingMessageActivities( _ encryptionUrl: String){
        /// process received acitivities
        let receivePendingActivityArray = self.receivedActivityList.filter({$0.encryptionKeyUrl == encryptionUrl})
        for activity in receivePendingActivityArray{
            self.processReceivedMessage(activity)
        }
        /// process post pending activities
        self.processFilePostingMessageActivities(encryptionUrl)
        
        /// process pending list requests if exist
        self.processPendingListRequest(encryptionUrl)
    }
    
    /// Process posting pending activities
    private func processFilePostingMessageActivities(_ encryptionUrl: String){
        if let roomResource = self.roomResourceList.filter({$0.encryptionUrl == encryptionUrl}).first,
            let keyMaterial = roomResource.keyMaterial
        {
            let postPendingActivityArray = self.pendingOperationList.filter({$0.encryptionUrl == encryptionUrl})
            for pendingOperation in postPendingActivityArray{
                pendingOperation.keyMaterial = keyMaterial
                if(pendingOperation.messageActivity.action == .post){
                    self.executeOperationQueue.addOperation(pendingOperation)
                    self.pendingOperationList.removeObject(pendingOperation)
                }else{
                    if let spaceUrl =  roomResource.spaceUrl{
                        pendingOperation.spaceUrl = spaceUrl
                        self.executeOperationQueue.addOperation(pendingOperation)
                        self.pendingOperationList.removeObject(pendingOperation)
                    }else{
                        self.requestSpaceUrl(convasationId: pendingOperation.messageActivity.conversationId!)
                    }
                }
            }
        }
    }
    
    private func processFilePostingMessageActivitiesWith( _ conversationId: String){
        if let roomResource = self.roomResourceList.filter({$0.conversationId == conversationId}).first,
            let keyMaterial = roomResource.keyMaterial,
            let encryptionUrl = roomResource.encryptionUrl
        {
            let postPendingActivityArray = self.pendingOperationList.filter({$0.messageActivity.conversationId == conversationId})
            for pendingOperation in postPendingActivityArray{
                pendingOperation.keyMaterial = keyMaterial
                pendingOperation.encryptionUrl = encryptionUrl
                if(pendingOperation.messageActivity.action == .post){
                    self.executeOperationQueue.addOperation(pendingOperation)
                    self.pendingOperationList.removeObject(pendingOperation)
                }else{
                    if let spaceUrl =  roomResource.spaceUrl{
                        pendingOperation.spaceUrl = spaceUrl
                        self.executeOperationQueue.addOperation(pendingOperation)
                        self.pendingOperationList.removeObject(pendingOperation)
                    }else{
                        self.requestSpaceUrl(convasationId: pendingOperation.messageActivity.conversationId!)
                    }
                }
            }
        }
    }
    /// Process List Acitivities Requests
    private func processPendingListRequest(_ encryptionUrl: String){
        if let roomResource = self.roomResourceList.filter({$0.encryptionUrl == encryptionUrl}).first,
            let keyMaterial = roomResource.keyMaterial
        {
            let conversationId = roomResource.conversationId
            let listActivityRqeustList = self.pendingListOperationList.filter({$0.conversationId == conversationId})
            for pendingOperation in listActivityRqeustList{
                pendingOperation.keyMaterial = keyMaterial
                self.executeOperationQueue.addOperation(pendingOperation)
                self.pendingListOperationList.removeObject(pendingOperation)
            }
        }
    }
    
    // MARK: KeyMaterial/EncryptionUrl/SpaceUrl Info Request Part
    
    private func requestEncryptionUrlFor(_ convasationId: String){
        
        let path = "conversations/" + convasationId
        let query = RequestParameter(["includeActivities": false,
                                      "includeParticipants": false
            ])
        let header : [String: String]  = [ "Authorization" : "Bearer " + self.accessTokenStr]
        let request = activityServiceBuilder().path(path)
            .query(query)
            .headers(header)
            .method(.get)
            .build()
        request.responseJSON{ (response: ServiceResponse<Any>) in
            switch response.result {
            case .success(let value):
                guard let responseDict = value as? [String: Any]
                    else{
                        return
                }
                if(responseDict["encryptionKeyUrl"] != nil  || responseDict["defaultActivityEncryptionKeyUrl"] != nil) {
                    let encryptionUrl = responseDict["encryptionKeyUrl"] != nil ? responseDict["encryptionKeyUrl"] : responseDict["defaultActivityEncryptionKeyUrl"]
                    if let room = self.roomResourceList.filter({$0.conversationId == convasationId}).first{
                        if(room.encryptionUrl == nil){
                            room.encryptionUrl = encryptionUrl as? String
                        }else{
                            return
                        }
                    }
                    let postPendingOperations = self.pendingOperationList.filter({$0.messageActivity.conversationId == convasationId})
                    for pendingOperation in postPendingOperations{
                        pendingOperation.messageActivity.encryptionKeyUrl = encryptionUrl as? String
                        pendingOperation.encryptionUrl = encryptionUrl as? String
                    }
                    self.requestKeyMaterial(encryptionUrl as! String)
                }else{
                    do{
                        let kmsRequest = try KmsRequest(requestId: self.uuid, clientId: self.deviceUrl.absoluteString , userId: self.userId, bearer: self.accessTokenStr, method: "create", uri: "/keys")
                        kmsRequest.additionalAttributes = ["count" : 1]
                        let serrizeData = kmsRequest.serialize()
                        let chiperText = try CjoseWrapper.ciphertext(fromContent: serrizeData?.data(using: .utf8), key: self.ephemeralKeyStr)
                        let kmsMessages = [chiperText]
                        let parameters = ["kmsMessages" : kmsMessages, "destination" : "unused" ] as [String : Any]
                        let header : [String: String]  = ["Cisco-Request-ID" : self.uuid,
                                                          "Authorization" : "Bearer " + self.accessTokenStr]
                        let url = URL(string: self.kmsMessageServerUri)
                        Alamofire.request(url!, method: .post, parameters: parameters, encoding: JSONEncoding.default, headers: header).responseString(completionHandler: { (response) in
                            SDKLogger.shared.debug("RequestKMS UnUsed Key Response ============  \(response)")
                            if self.noEncryptionConvasationList.filter({$0 == convasationId}).first == nil{
                                self.noEncryptionConvasationList.append(convasationId)
                            }
                        })
                    }catch let error as NSError{
                        SDKLogger.shared.debug("Error - CreateKMSReuqes: \(error.description)")
                    }
                }
                break
            case .failure:
                let error = ActivityError.encryptionUrlFetchFail
                let tempError = Result<MessageActivity>.failure(error)
                self.cancelPendigActivitiesFor(convasationId, result: tempError)
                break
            }
        }
    }
    
    
    private func requestKeyMaterial(_ encryptionUrl: String){
        if let roomResouce = self.roomResourceList.filter({$0.encryptionUrl == encryptionUrl}).first,
            let _ = roomResouce.keyMaterial{
            return
        }else{
            do{
                let kmsRequest = try KmsRequest(requestId: self.uuid, clientId: self.deviceUrl.absoluteString , userId: self.userId, bearer: self.accessTokenStr, method: "retrieve", uri: encryptionUrl)
                let serrizeData = kmsRequest.serialize()
                let chiperText = try CjoseWrapper.ciphertext(fromContent: serrizeData?.data(using: .utf8), key: self.ephemeralKeyStr)
                let kmsMessages = [chiperText]
                let parameters = ["kmsMessages" : kmsMessages, "destination" : "unused" ] as [String : Any]
                let header : [String: String]  = ["Cisco-Request-ID" : self.uuid,
                                                  "Authorization" : "Bearer " + self.accessTokenStr]
                let url = URL(string: kmsMessageServerUri)
                Alamofire.request(url!, method: .post, parameters: parameters, encoding: JSONEncoding.default, headers: header).responseString(completionHandler: { (response) in
                    self.kmsRequestList.append(kmsRequest)
                    SDKLogger.shared.debug("RequestKMS Material Response ============  \(response)")
                })
            }catch let error as NSError{
                SDKLogger.shared.debug("Error - CreateKMSReuqes: \(error.description)")
            }
        }
    }
    
    private func requestSpaceUrl(convasationId: String){
        let path = "conversations/" + convasationId + "/space"
        let header : [String: String]  = [ "Authorization" : "Bearer " + self.accessTokenStr]
        let request = activityServiceBuilder().path(path)
            .headers(header)
            .method(.put)
            .build()
        request.responseJSON{ (response: ServiceResponse<Any>) in
            switch response.result {
            case .success(let value):
                guard let responseDict = value as? [String: Any]
                    else{
                        return;
                }
                if let room = self.roomResourceList.filter({$0.conversationId == convasationId}).first{
                    room.spaceUrl = responseDict["spaceUrl"]! as? String
                    self.processFilePostingMessageActivities(room.encryptionUrl!)
                    return;
                }
                break
            case .failure:
                break
            }
        }
    }
    
    // MARK: Client Info Request Part
    private func finishClientInfoRequest(success: Bool){
        if(success){
            if(self.kmsCluster != nil && self.userId != nil){
                self.requestEphemeralKey()
                if(self.ephemeralKeyRequest != nil){
                    let deadlineTime = DispatchTime.now() + .seconds(20)
                    DispatchQueue.main.asyncAfter(deadline: deadlineTime) {
                        if(!self.ephemeralKeyFetched){
                            self.ephemeralKeyRequest = nil
                            let error = ActivityError.ephemaralKeyFetchFail
                            let tempError = Result<MessageActivity>.failure(error)
                            self.cancelAllPendingActivities(result: tempError)
                        }
                    }
                }
            }
        }else{
            let error = ActivityError.clientInfoFetchFail
            let tempError = Result<MessageActivity>.failure(error)
            self.cancelAllPendingActivities(result: tempError)
        }
    }
    
    private func requestClientInfo(){
        let userIdRequest = activityServiceBuilder().path("users")
            .method(.get)
            .build()
        userIdRequest.responseJSON{ (response: ServiceResponse<Any>) in
            switch response.result {
            case .success(let value):
                guard let responseDict = value as? [String: Any]
                    else{
                        return;
                }
                if let userid = responseDict["id"]{
                    self.userId = userid as? String
                }
                self.finishClientInfoRequest(success: true)
                break
            case .failure:
                self.finishClientInfoRequest(success: false)
                break
            }
        }
        
        let clusterRequest = kmsRequestBuilder().path("kms")
            .method(.get)
            .build()
        clusterRequest.responseJSON{ (response: ServiceResponse<Any>) in
            switch response.result {
            case .success(let value):
                guard let responseDict = value as? [String: String]
                    else{
                        return;
                }
                self.kmsCluster = responseDict["kmsCluster"]
                self.rsaPublicKey = responseDict["rsaPublicKey"]
                self.finishClientInfoRequest(success: true)
                break
            case .failure:
                self.finishClientInfoRequest(success: false)
                break
            }
        }
    }
    
    private func requestEphemeralKey(){
        if(self.ephemeralKeyRequest != nil || self.ephemeralKeyFetched){
            return
        }
        self.authenticator.accessToken { (res) in
            self.accessTokenStr = res!
            do{
                guard let clusterUri = self.kmsCluster
                    else {
                        return
                }
                let kmsClusterUri = clusterUri + "/ecdhe"
                self.ephemeralKeyRequest = try KmsEphemeralKeyRequest(requestId: self.uuid, clientId: self.deviceUrl.absoluteString , userId: self.userId, bearer: self.accessTokenStr , method: "create", uri: kmsClusterUri, kmsStaticKey: self.rsaPublicKey!)
                
                guard let message = self.ephemeralKeyRequest?.message
                    else {
                        self.ephemeralKeyRequest = nil
                        return
                }
                
                let parameters : [String: String] = ["kmsMessages" : message, "destination" : clusterUri]
                let header : [String: String]  = ["Cisco-Request-ID" : self.uuid,
                                                  "Authorization" : "Bearer " + self.accessTokenStr]
                
                let url = URL(string: self.kmsMessageServerUri)
                Alamofire.request(url!, method: .post, parameters: parameters, encoding: JSONEncoding.default, headers: header).responseString(completionHandler: { (response) in
                    SDKLogger.shared.debug("Request EphemeralKey Response ============ \(response)")
                })
                
            }catch let error as NSError{
                self.ephemeralKeyRequest = nil
                SDKLogger.shared.debug("Error - RequestEphemeralKey \(error.description)")
            }
        }
        
    }
    
    // MARk: Message Operation Manage
    private func cancelAllPendingActivities(result: Result<MessageActivity>){
        for pendingOperation in self.pendingOperationList{
            let tempRes = ServiceResponse<MessageActivity>(nil, result)
            pendingOperation.completionHandler(tempRes)
        }
        self.pendingOperationList.removeAll()
    }
    private func cancelPendigActivitiesFor(_ conversationId: String, result: Result<MessageActivity>){
        for pendingOperation in self.pendingOperationList{
            if(pendingOperation.messageActivity.conversationId == conversationId){
                let tempRes = ServiceResponse<MessageActivity>(nil, result)
                pendingOperation.completionHandler(tempRes)
                self.pendingOperationList.removeObject(pendingOperation)
            }
        }
    }
    
    //MARK: RequestBuilders
    
    private func activityServiceBuilder() -> ServiceRequest.ActivityServerBuilder {
        return ServiceRequest.ActivityServerBuilder(authenticator)
    }
    
    private func flagRequestBuilder() ->ServiceRequest.RainDropServerBuilder {
        return ServiceRequest.RainDropServerBuilder(authenticator).path("flags")
    }
    
    private func kmsRequestBuilder() -> ServiceRequest.KmsServerBuilder {
        return ServiceRequest.KmsServerBuilder(authenticator)
    }
    
    
    private var isClientReady: Bool{
        get{
            if let _ = self.kmsCluster,
                let _ = self.rsaPublicKey,
                let _ = self.userId
            {
                return true
            }else{
                return false
            }
        }
    }
    
    private func encryptKeyReadyFor(_ conversationId: String) -> Bool{
        if let room = self.roomResourceList.filter({$0.conversationId == conversationId}).first{
            if let _ = room.encryptionUrl,
                let _ = room.keyMaterial
            {
                return true
            }else{
                return false
            }
        }else{
            return false
        }
    }
    private func readyToShareFor(_ conversationId: String) -> Bool{
        if let room = self.roomResourceList.filter({$0.conversationId == conversationId}).first{
            if let _ = room.encryptionUrl,
                let _ = room.keyMaterial,
                let _ = room.spaceUrl
            {
                return true
            }else{
                return false
            }
        }else{
            return false
        }
    }
    
}

extension Array {
    mutating func removeObject(equality: (Element) -> Bool) -> Element? {
        for (idx, element) in self.enumerated() {
            if equality(element) {
                return self.remove(at: idx);
            }
        }
        return nil
    }
}

