//
//  CollapsedEvents.m
//
//  Copyright (C) 2013 IRCCloud, Ltd.
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.


#import "CollapsedEvents.h"
#import "ColorFormatter.h"

@implementation CollapsedEvent
-(NSComparisonResult)compare:(CollapsedEvent *)aEvent {
    if(_type == aEvent.type)
        return [_nick compare:aEvent.nick];
    else if(_type < aEvent.type)
        return NSOrderedAscending;
    else
        return NSOrderedDescending;
}
-(NSString *)description {
    return [NSString stringWithFormat:@"{type: %i, chan: %@, nick: %@, oldNick: %@, hostmask: %@, fromMode: %@, targetMode: %@, mode: %i, msg: %@}", _type, _chan, _nick, _oldNick, _hostname, _fromMode, _targetMode, _mode, _msg];
}
@end

@implementation CollapsedEvents
-(id)init {
    self = [super init];
    if(self) {
        _data = [[NSMutableArray alloc] init];
    }
    return self;
}
-(void)clear {
    @synchronized(_data) {
        [_data removeAllObjects];
    }
}
-(CollapsedEvent *)findEvent:(NSString *)nick chan:(NSString *)chan {
    @synchronized(_data) {
        for(CollapsedEvent *event in _data) {
            if([[event.nick lowercaseString] isEqualToString:[nick lowercaseString]] && [[event.chan lowercaseString] isEqualToString:[chan lowercaseString]])
                return event;
        }
        return nil;
    }
}
-(void)addCollapsedEvent:(CollapsedEvent *)event {
    @synchronized(_data) {
        CollapsedEvent *e = nil;
        
        if(event.type < kCollapsedEventNickChange) {
            if(event.oldNick.length > 0 && event.type != kCollapsedEventMode) {
                e = [self findEvent:event.oldNick chan:event.chan];
                if(e)
                    e.nick = event.nick;
            }
            
            if(!e)
                e = [self findEvent:event.nick chan:event.chan];
            
            if(e) {
                if(e.type == kCollapsedEventMode) {
                    e.type = event.type;
                    e.msg = event.msg;
                    if(event.fromMode)
                        e.fromMode = event.fromMode;
                    if(event.targetMode)
                        e.targetMode = event.targetMode;
                } else if(event.type == kCollapsedEventMode) {
                    e.fromMode = event.targetMode;
                } else if(event.type == e.type) {
                } else if(event.type == kCollapsedEventJoin) {
                    e.type = kCollapsedEventPopOut;
                    e.fromMode = event.fromMode;
                } else if(e.type == kCollapsedEventPopOut) {
                    e.type = event.type;
                } else {
                    e.type = kCollapsedEventPopIn;
                }
                if(event.mode > 0)
                    e.mode = event.mode;
            } else {
                [_data addObject:event];
            }
        } else {
            if(event.type == kCollapsedEventNickChange) {
                for(CollapsedEvent *e1 in _data) {
                    if(e1.type == kCollapsedEventNickChange && [[e1.nick lowercaseString] isEqualToString:[event.oldNick lowercaseString]]) {
                        if([[e1.oldNick lowercaseString] isEqualToString:[event.nick lowercaseString]]) {
                            [_data removeObject:e1];
                        } else {
                            e1.nick = event.nick;
                        }
                        return;
                    }
                    if((e1.type == kCollapsedEventJoin || e1.type == kCollapsedEventPopOut) && [[e1.nick lowercaseString] isEqualToString:[event.oldNick lowercaseString]]) {
                        e1.oldNick = event.oldNick;
                        e1.nick = event.nick;
                        return;
                    }
                    if((e1.type == kCollapsedEventQuit || e1.type == kCollapsedEventPart) && [[e1.nick lowercaseString] isEqualToString:[event.oldNick lowercaseString]]) {
                        e1.type = kCollapsedEventPopOut;
                        for(CollapsedEvent *e2 in _data) {
                            if(e2.type == kCollapsedEventJoin && [[e2.nick lowercaseString] isEqualToString:[event.oldNick lowercaseString]]) {
                                [_data removeObject:e2];
                                break;
                            }
                        }
                        return;
                    }
                }
                [_data addObject:event];
            } else {
                [_data addObject:event];
            }
        }
    }
}
-(BOOL)addEvent:(Event *)event {
    @synchronized(_data) {
        CollapsedEvent *c;
        if([event.type hasSuffix:@"user_channel_mode"]) {
            if(event.ops) {
                for(NSDictionary *op in [event.ops objectForKey:@"add"]) {
                    c = [[CollapsedEvent alloc] init];
                    c.type = kCollapsedEventMode;
                    c.nick = [op objectForKey:@"param"];
                    c.oldNick = event.from;
                    c.hostname = event.hostmask;
                    c.fromMode = event.fromMode;
                    c.targetMode = event.targetMode;
                    c.chan = event.chan;
                    NSString *mode = [op objectForKey:@"mode"];
                    if([mode rangeOfString:@"q"].location != NSNotFound)
                        c.mode = kCollapsedModeAdmin;
                    else if([mode rangeOfString:@"a"].location != NSNotFound)
                        c.mode = kCollapsedModeOwner;
                    else if([mode rangeOfString:@"o"].location != NSNotFound)
                        c.mode = kCollapsedModeOp;
                    else if([mode rangeOfString:@"h"].location != NSNotFound)
                        c.mode = kCollapsedModeHalfOp;
                    else if([mode rangeOfString:@"v"].location != NSNotFound)
                        c.mode = kCollapsedModeVoice;
                    else
                        return NO;
                    [self addCollapsedEvent:c];
                }
                for(NSDictionary *op in [event.ops objectForKey:@"remove"]) {
                    c = [[CollapsedEvent alloc] init];
                    c.type = kCollapsedEventMode;
                    c.nick = [op objectForKey:@"param"];
                    c.oldNick = event.from;
                    c.hostname = event.hostmask;
                    c.fromMode = event.fromMode;
                    c.targetMode = event.targetMode;
                    c.chan = event.chan;
                    NSString *mode = [op objectForKey:@"mode"];
                    if([mode rangeOfString:@"q"].location != NSNotFound)
                        c.mode = kCollapsedModeDeAdmin;
                    else if([mode rangeOfString:@"a"].location != NSNotFound)
                        c.mode = kCollapsedModeDeOwner;
                    else if([mode rangeOfString:@"o"].location != NSNotFound)
                        c.mode = kCollapsedModeDeOp;
                    else if([mode rangeOfString:@"h"].location != NSNotFound)
                        c.mode = kCollapsedModeDeHalfOp;
                    else if([mode rangeOfString:@"v"].location != NSNotFound)
                        c.mode = kCollapsedModeDeVoice;
                    else
                        return NO;
                    [self addCollapsedEvent:c];
                }
            }
        } else {
            c = [[CollapsedEvent alloc] init];
            c.nick = event.nick;
            c.hostname = event.hostmask;
            c.fromMode = event.fromMode;
            c.chan = event.chan;
            if([event.type hasSuffix:@"joined_channel"]) {
                c.type = kCollapsedEventJoin;
            } else if([event.type hasSuffix:@"parted_channel"]) {
                c.type = kCollapsedEventPart;
                c.msg = event.msg;
            } else if([event.type hasSuffix:@"quit"]) {
                c.type = kCollapsedEventQuit;
                c.msg = event.msg;
            } else if([event.type hasSuffix:@"nickchange"]) {
                c.type = kCollapsedEventNickChange;
                c.oldNick = event.oldNick;
            } else {
                return NO;
            }
            [self addCollapsedEvent:c];
        }
        return YES;
    }
}
-(NSString *)was:(CollapsedEvent *)e {
    NSString *output = @"";
    
    if(e.oldNick && e.type != kCollapsedEventMode)
        output = [NSString stringWithFormat:@"was %@", e.oldNick];
    if(e.mode > 0) {
        if(output.length > 0)
            output = [output stringByAppendingString:@"; "];
        switch(e.mode) {
            case kCollapsedModeOwner:
                output = [output stringByAppendingString:@"promoted to owner"];
                break;
            case kCollapsedModeDeOwner:
                output = [output stringByAppendingString:@"demoted from owner"];
                break;
            case kCollapsedModeAdmin:
                output = [output stringByAppendingString:@"promoted to admin"];
                break;
            case kCollapsedModeDeAdmin:
                output = [output stringByAppendingString:@"demoted from admin"];
                break;
            case kCollapsedModeOp:
                output = [output stringByAppendingString:@"opped"];
                break;
            case kCollapsedModeDeOp:
                output = [output stringByAppendingString:@"de-opped"];
                break;
            case kCollapsedModeHalfOp:
                output = [output stringByAppendingString:@"halfopped"];
                break;
            case kCollapsedModeDeHalfOp:
                output = [output stringByAppendingString:@"de-halfopped"];
                break;
            case kCollapsedModeVoice:
                output = [output stringByAppendingString:@"voiced"];
                break;
            case kCollapsedModeDeVoice:
                output = [output stringByAppendingString:@"devoiced"];
                break;
        }
    }
    
    if(output.length)
        output = [NSString stringWithFormat:@" (%@)", output];
    
    return output;
}
-(NSString *)collapse:(BOOL)showChan {
    @synchronized(_data) {
        NSString *output;
        
        if(_data.count == 0)
            return nil;
        
        if(_data.count == 1) {
            CollapsedEvent *e = [_data objectAtIndex:0];
            switch(e.type) {
                case kCollapsedEventMode:
                    output = [NSString stringWithFormat:@"%@ was ", [ColorFormatter formatNick:e.nick mode:e.targetMode]];
                    switch(e.mode) {
                        case kCollapsedModeOwner:
                            output = [output stringByAppendingFormat:@"promoted to owner (%cE7AA00+q%c)", COLOR_RGB, CLEAR];
                            break;
                        case kCollapsedModeDeOwner:
                            output = [output stringByAppendingFormat:@"demoted from owner (%cE7AA00-q%c)", COLOR_RGB, CLEAR];
                            break;
                        case kCollapsedModeAdmin:
                            output = [output stringByAppendingFormat:@"promoted to admin (%c6500A5+a%c)", COLOR_RGB, CLEAR];
                            break;
                        case kCollapsedModeDeAdmin:
                            output = [output stringByAppendingFormat:@"demoted from admin (%c6500A5-a%c)", COLOR_RGB, CLEAR];
                            break;
                        case kCollapsedModeOp:
                            output = [output stringByAppendingFormat:@"opped (%cBA1719+o%c)", COLOR_RGB, CLEAR];
                            break;
                        case kCollapsedModeDeOp:
                            output = [output stringByAppendingFormat:@"de-opped (%cBA1719-o%c)", COLOR_RGB, CLEAR];
                            break;
                        case kCollapsedModeHalfOp:
                            output = [output stringByAppendingFormat:@"halfopped (%cB55900+h%c)", COLOR_RGB, CLEAR];
                            break;
                        case kCollapsedModeDeHalfOp:
                            output = [output stringByAppendingFormat:@"de-halfopped (%cB55900-h%c)", COLOR_RGB, CLEAR];
                            break;
                        case kCollapsedModeVoice:
                            output = [output stringByAppendingFormat:@"voiced (%c25B100+v%c)", COLOR_RGB, CLEAR];
                            break;
                        case kCollapsedModeDeVoice:
                            output = [output stringByAppendingFormat:@"devoiced (%c25B100-v%c)", COLOR_RGB, CLEAR];
                            break;
                    }
                    if(e.oldNick)
                        output = [output stringByAppendingFormat:@" by %@", [ColorFormatter formatNick:e.oldNick mode:e.fromMode]];
                    break;
                case kCollapsedEventJoin:
                    if(showChan)
                        output = [NSString stringWithFormat:@"→ %@%@ joined %@ (%@)", [ColorFormatter formatNick:e.nick mode:e.fromMode], [self was:e], e.chan, e.hostname];
                    else
                        output = [NSString stringWithFormat:@"→ %@%@ joined (%@)", [ColorFormatter formatNick:e.nick mode:e.fromMode], [self was:e], e.hostname];
                    break;
                case kCollapsedEventPart:
                    if(showChan)
                        output = [NSString stringWithFormat:@"← %@%@ left %@ (%@)", [ColorFormatter formatNick:e.nick mode:e.fromMode], [self was:e], e.chan, e.hostname];
                    else
                        output = [NSString stringWithFormat:@"← %@%@ left (%@)", [ColorFormatter formatNick:e.nick mode:e.fromMode], [self was:e], e.hostname];
                    if(e.msg.length > 0)
                        output = [output stringByAppendingFormat:@": %@", e.msg];
                    break;
                case kCollapsedEventQuit:
                    output = [NSString stringWithFormat:@"⇐ %@%@ quit", [ColorFormatter formatNick:e.nick mode:e.fromMode], [self was:e]];
                    if(e.hostname.length > 0)
                        output = [output stringByAppendingFormat:@" (%@)", e.hostname];
                    if(e.msg.length > 0)
                        output = [output stringByAppendingFormat:@": %@", e.msg];
                    break;
                case kCollapsedEventNickChange:
                    output = [NSString stringWithFormat:@"%@ → %@", e.oldNick, [ColorFormatter formatNick:e.nick mode:e.fromMode]];
                    break;
                case kCollapsedEventPopIn:
                    output = [NSString stringWithFormat:@"↔ %@%@ popped in", [ColorFormatter formatNick:e.nick mode:e.fromMode], [self was:e]];
                    if(showChan)
                        output = [output stringByAppendingFormat:@" %@", e.chan];
                    break;
                case kCollapsedEventPopOut:
                    output = [NSString stringWithFormat:@"↔ %@%@ nipped out", [ColorFormatter formatNick:e.nick mode:e.fromMode], [self was:e]];
                    if(showChan)
                        output = [output stringByAppendingFormat:@" %@", e.chan];
                    break;
            }
        } else {
            [_data sortUsingSelector:@selector(compare:)];
            NSEnumerator *i = [_data objectEnumerator];
            CollapsedEvent *last = nil;
            CollapsedEvent *next = [i nextObject];
            CollapsedEvent *e;
            int groupcount = 0;
            NSMutableString *message = [[NSMutableString alloc] init];
            
            while(next) {
                e = next;
                
                next = [i nextObject];
                
                if(message.length > 0 && e.type < kCollapsedEventNickChange && ((next == nil || next.type != e.type) && last != nil && last.type == e.type)) {
					if(groupcount == 1) {
                        [message deleteCharactersInRange:NSMakeRange(message.length - 2, 2)];
                        [message appendString:@" "];
                    }
                    [message appendString:@"and "];
				}
                
                if(last == nil || last.type != e.type) {
                    switch(e.type) {
                        case kCollapsedEventMode:
                            if(message.length)
                                [message appendString:@"• "];
                            [message appendString:@"mode: "];
                            break;
                        case kCollapsedEventJoin:
                            [message appendString:@"→ "];
                            break;
                        case kCollapsedEventPart:
                            [message appendString:@"← "];
                            break;
                        case kCollapsedEventQuit:
                            [message appendString:@"⇐ "];
                            break;
                        case kCollapsedEventNickChange:
                            if(message.length)
                                [message appendString:@"• "];
                            break;
                        case kCollapsedEventPopIn:
                        case kCollapsedEventPopOut:
                            [message appendString:@"↔ "];
                            break;
                    }
                }
                
                if(e.type == kCollapsedEventNickChange) {
                    [message appendFormat:@"%@ → %@", e.oldNick, [ColorFormatter formatNick:e.nick mode:e.fromMode]];
                    NSString *oldNick = e.oldNick;
                    e.oldNick = nil;
                    [message appendString:[self was:e]];
                    e.oldNick = oldNick;
                } else if(!showChan) {
                    [message appendString:[ColorFormatter formatNick:e.nick mode:(e.type == kCollapsedEventMode)?e.targetMode:e.fromMode]];
                    [message appendString:[self was:e]];
                }
                
                if((next == nil || next.type != e.type) && !showChan) {
                    switch(e.type) {
                        case kCollapsedEventJoin:
                            [message appendString:@" joined"];
                            break;
                        case kCollapsedEventPart:
                            [message appendString:@" left"];
                            break;
                        case kCollapsedEventQuit:
                            [message appendString:@" quit"];
                            break;
                        case kCollapsedEventPopIn:
                            [message appendString:@" popped in"];
                            break;
                        case kCollapsedEventPopOut:
                            [message appendString:@" nipped out"];
                            break;
                        default:
                            break;
                    }
                } else if(showChan) {
                    if(groupcount == 0) {
                        [message appendString:[ColorFormatter formatNick:e.nick mode:(e.type == kCollapsedEventMode)?e.targetMode:e.fromMode]];
                        [message appendString:[self was:e]];
                        switch(e.type) {
                            case kCollapsedEventJoin:
                                [message appendString:@" joined "];
                                break;
                            case kCollapsedEventPart:
                                [message appendString:@" left "];
                                break;
                            case kCollapsedEventQuit:
                                [message appendString:@" quit"];
                                break;
                            case kCollapsedEventPopIn:
                                [message appendString:@" popped in "];
                                break;
                            case kCollapsedEventPopOut:
                                [message appendString:@" nipped out "];
                                break;
                            default:
                                break;
                        }
                    }
                    if(e.type != kCollapsedEventQuit && e.chan)
                        [message appendString:e.chan];
                }
                
                if(next != nil && next.type == e.type) {
                    [message appendString:@", "];
                    groupcount++;
                } else if(next != nil) {
                    [message appendString:@" "];
                    groupcount = 0;
                }
                
                last = e;
            }
            output = message;
        }
        
        return output;
    }
}
@end
