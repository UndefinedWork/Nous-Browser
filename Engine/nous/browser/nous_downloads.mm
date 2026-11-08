// Downloads on top of Chrome's own ChromeDownloadManagerDelegate.
//
// Chrome still decides the danger type, safe-browsing verdict, MIME type and
// default name. Nous only replaces the final step (where the bytes go): the
// Swift coordinator chooses a same-volume staging file, then installs it
// atomically after completion. Unlike CEF, the DownloadItem is observed
// directly, so progress keeps flowing after the source tab has closed.

#import "nous/public/NBChromiumDownloads.h"

#include <map>
#include <memory>
#include <string>

#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "chrome/browser/download/chrome_download_manager_delegate.h"
#include "chrome/browser/download/download_core_service.h"
#include "chrome/browser/download/download_core_service_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "components/download/public/common/download_item.h"
#include "components/download/public/common/download_target_info.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/download_item_utils.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/web_contents.h"
#include "nous/browser/nous_internal.h"

@interface NBChromiumDownloadJob ()
@property(nonatomic, readwrite, copy) NSString *identifier;
@property(nonatomic, readwrite, copy) NSString *suggestedFilename;
@property(nonatomic, readwrite, copy) NSString *mimeType;
@property(nonatomic, readwrite, weak) NSWindow *sourceWindow;
@property(nonatomic, readwrite) BOOL hasDurableObservation;
@property(nonatomic, readwrite, copy) NSDictionary<NSString *, id> *snapshot;
- (void)itemUpdated;
- (void)itemDestroyed;
@end

@interface NBChromiumDownloadCenter ()
- (void)beginItem:(download::DownloadItem *)item
           target:(download::DownloadTargetInfo)info
         callback:(download::DownloadTargetCallback)callback;
- (void)finish:(NBChromiumDownloadJob *)job;
@end

namespace {

class ItemObserver final : public download::DownloadItem::Observer {
 public:
  ItemObserver(NBChromiumDownloadJob *job, download::DownloadItem *item)
      : job_(job), item_(item) {
    item_->AddObserver(this);
  }
  ~ItemObserver() override {
    if (item_) item_->RemoveObserver(this);
  }
  download::DownloadItem *item() const { return item_; }
  void OnDownloadUpdated(download::DownloadItem *) override { [job_ itemUpdated]; }
  void OnDownloadDestroyed(download::DownloadItem *) override {
    item_->RemoveObserver(this);
    item_ = nullptr;
    [job_ itemDestroyed];
  }

 private:
  __weak NBChromiumDownloadJob *job_;
  raw_ptr<download::DownloadItem> item_;
};

int StateCode(download::DownloadItem *item) {
  switch (item->GetState()) {
    case download::DownloadItem::COMPLETE: return 1;
    case download::DownloadItem::CANCELLED: return 2;
    case download::DownloadItem::INTERRUPTED: return 3;
    default: return 0;
  }
}

// Wraps Chrome's delegate: Chrome computes the target, Nous redirects it.
class NousDownloadManagerDelegate final : public ChromeDownloadManagerDelegate {
 public:
  explicit NousDownloadManagerDelegate(Profile *profile)
      : ChromeDownloadManagerDelegate(profile) {}

  bool DetermineDownloadTarget(download::DownloadItem *item,
                               download::DownloadTargetCallback *callback) override {
    download::DownloadTargetCallback original = std::move(*callback);
    const std::string guid = item->GetGuid();
    content::BrowserContext *context = content::DownloadItemUtils::GetBrowserContext(item);
    content::DownloadManager *manager = context ? context->GetDownloadManager() : nullptr;
    *callback = base::BindOnce(
        [](std::string guid, content::DownloadManager *manager,
           download::DownloadTargetCallback original,
           download::DownloadTargetInfo info) {
          download::DownloadItem *found = manager ? manager->GetDownloadByGuid(guid) : nullptr;
          if (!found || info.target_path.empty() ||
              info.interrupt_reason != download::DOWNLOAD_INTERRUPT_REASON_NONE) {
            std::move(original).Run(std::move(info));
            return;
          }
          [[NBChromiumDownloadCenter sharedCenter] beginItem:found
                                                      target:std::move(info)
                                                    callback:std::move(original)];
        },
        guid, manager, std::move(original));
    return ChromeDownloadManagerDelegate::DetermineDownloadTarget(item, callback);
  }
};

}  // namespace

@implementation NBChromiumDownloadJob {
  std::unique_ptr<ItemObserver> _observer;
  download::DownloadTargetInfo _info;
  download::DownloadTargetCallback _callback;
  BOOL _finished;
}

- (void)attachItem:(download::DownloadItem *)item
            target:(download::DownloadTargetInfo)info
          callback:(download::DownloadTargetCallback)callback {
  _info = std::move(info);
  _callback = std::move(callback);
  _observer = std::make_unique<ItemObserver>(self, item);
  self.hasDurableObservation = YES;
  self.snapshot = @{@"state" : @0, @"received" : @(item->GetReceivedBytes()),
                    @"total" : @(item->GetTotalBytes()), @"percent" : @(item->PercentComplete())};
}

- (void)chooseDestination:(NSURL *)url {
  if (_finished || !_callback) return;
  if (!url.isFileURL || url.path.length == 0) { [self cancel]; return; }
  base::FilePath path(base::SysNSStringToUTF8(url.path));
  _info.target_path = path;
  _info.intermediate_path = path.AddExtension(FILE_PATH_LITERAL("crdownload"));
  _info.display_name = path.BaseName();
  _info.target_disposition = download::DownloadItem::TARGET_DISPOSITION_OVERWRITE;
  std::move(_callback).Run(std::move(_info));
}

- (void)itemUpdated {
  download::DownloadItem *item = _observer ? _observer->item() : nullptr;
  if (_finished || !item) return;
  // Before the host has chosen a destination Chrome may already be receiving
  // bytes into a temporary file; report only real target progress.
  if (_callback && item->GetState() == download::DownloadItem::IN_PROGRESS) return;
  int state = StateCode(item);
  self.snapshot = @{@"state" : @(state), @"paused" : @(item->IsPaused()),
                    @"reason" : @(item->GetLastReason()), @"percent" : @(item->PercentComplete()),
                    @"received" : @(item->GetReceivedBytes()), @"total" : @(item->GetTotalBytes()),
                    @"speed" : @(item->CurrentSpeed()),
                    @"path" : base::SysUTF8ToNSString(item->GetFullPath().value())};
  if (state != 0) {
    _finished = YES;
    // Interrupted downloads are not resumed silently; drop the partial file.
    if (state == 3) item->Cancel(false);
    [[NBChromiumDownloadCenter sharedCenter] finish:self];
  }
  if (self.updateHandler) self.updateHandler(self);
}

- (void)itemDestroyed {
  if (_finished) return;
  _finished = YES;
  NSMutableDictionary *result = [self.snapshot mutableCopy] ?: [NSMutableDictionary new];
  result[@"state"] = @3;
  result[@"reason"] = @(-1);
  self.snapshot = result;
  [[NBChromiumDownloadCenter sharedCenter] finish:self];
  if (self.updateHandler) self.updateHandler(self);
}

- (void)cancel {
  if (_finished) return;
  _finished = YES;
  if (_callback) {
    // An empty target path cancels target determination in content.
    download::DownloadTargetInfo cancelled;
    cancelled.interrupt_reason = download::DOWNLOAD_INTERRUPT_REASON_USER_CANCELED;
    std::move(_callback).Run(std::move(cancelled));
  } else if (download::DownloadItem *item = _observer ? _observer->item() : nullptr) {
    item->Cancel(true);
  }
  NSMutableDictionary *result = [self.snapshot mutableCopy] ?: [NSMutableDictionary new];
  result[@"state"] = @2;
  result[@"explicitCancellation"] = @YES;
  self.snapshot = result;
  [[NBChromiumDownloadCenter sharedCenter] finish:self];
  if (self.updateHandler) self.updateHandler(self);
}
@end

@implementation NBChromiumDownloadCenter {
  NSMutableDictionary<NSString *, NBChromiumDownloadJob *> *_jobs;
}

+ (instancetype)sharedCenter {
  static NBChromiumDownloadCenter *center;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ center = [NBChromiumDownloadCenter new]; });
  return center;
}

- (instancetype)init {
  if ((self = [super init])) _jobs = [NSMutableDictionary new];
  return self;
}

- (NSUInteger)activeDownloadCount { return _jobs.count; }

- (void)beginItem:(download::DownloadItem *)item
           target:(download::DownloadTargetInfo)info
         callback:(download::DownloadTargetCallback)callback {
  NBChromiumDownloadJob *job = [NBChromiumDownloadJob new];
  job.identifier = NSUUID.UUID.UUIDString;
  job.suggestedFilename = base::SysUTF8ToNSString(info.target_path.BaseName().value());
  job.mimeType = base::SysUTF8ToNSString(info.mime_type.empty() ? item->GetMimeType() : info.mime_type);
  content::WebContents *contents = content::DownloadItemUtils::GetWebContents(item);
  job.sourceWindow = contents ? nous::WindowForWebContents(contents) : nil;
  [job attachItem:item target:std::move(info) callback:std::move(callback)];
  _jobs[job.identifier] = job;
  if (self.newDownloadHandler) self.newDownloadHandler(job);
  else [job cancel];
}

- (void)finish:(NBChromiumDownloadJob *)job {
  if (job.identifier) [_jobs removeObjectForKey:job.identifier];
}

- (void)cancelAll {
  for (NBChromiumDownloadJob *job in [_jobs.allValues copy]) [job cancel];
}
@end

namespace nous {
void InstallDownloadDelegate(Profile *profile) {
  DownloadCoreService *service = DownloadCoreServiceFactory::GetForBrowserContext(profile);
  if (service)
    service->SetDownloadManagerDelegateForTesting(
        std::make_unique<NousDownloadManagerDelegate>(profile));
}
}  // namespace nous
