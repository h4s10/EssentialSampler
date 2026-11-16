#pragma once
#include "Engine.hpp"
#include <functional>
namespace hasio { inline constexpr int editorWidth = 1280, editorHeight = 860; }
#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
@interface HLView : NSView
- (instancetype)initWithModel:(std::shared_ptr<hasio::Model>)model;
- (void)setBeginEdit:(std::function<void(uint32_t)>)begin
              change:(std::function<void(uint32_t, double)>)change
                 end:(std::function<void(uint32_t)>)end
               dirty:(std::function<void()>)dirty;
- (void)setHosted:(BOOL)hosted;
- (void)detach;
- (void)loadPath:(NSString*)path;
- (void)stopNotes;
@end
#endif
