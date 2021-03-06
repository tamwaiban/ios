//
//  EventsDataSource.m
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


#import "EventsDataSource.h"
#import "UIColor+IRCCloud.h"
#import "ColorFormatter.h"
#import "BuffersDataSource.h"
#import "ServersDataSource.h"
#import "ChannelsDataSource.h"
#import "UsersDataSource.h"
#import "Ignore.h"

@implementation Event
-(NSComparisonResult)compare:(Event *)aEvent {
    if(aEvent.pending && !_pending)
        return NSOrderedAscending;
    if(!aEvent.pending && _pending)
        return NSOrderedDescending;
    if(aEvent.eid > _eid)
        return NSOrderedAscending;
    else if(aEvent.eid < _eid)
        return NSOrderedDescending;
    else
        return NSOrderedSame;
}
-(BOOL)isImportant:(NSString *)bufferType {
    if(_isSelf)
        return NO;
    if(!_type)
        return NO;
    if([_type isEqualToString:@"notice"] && [bufferType isEqualToString:@"console"])
        if(_server || _toChan)
            return NO;
    return ([_type isEqualToString:@"buffer_msg"]
            ||[_type isEqualToString:@"buffer_me_msg"]
            ||[_type isEqualToString:@"notice"]
            ||[_type isEqualToString:@"channel_invite"]
            ||[_type isEqualToString:@"callerid"]
            ||[_type isEqualToString:@"wallops"]);
}
-(NSString *)description {
    return [NSString stringWithFormat:@"{cid: %i, bid: %i, eid: %f, group: %f, type: %@, msg: %@}", _cid, _bid, _eid, _groupEid, _type, _msg];
}
-(NSString *)ignoreMask {
    if(!_ignoreMask) {
        NSString *from = _from;
        if(!from.length)
            from = _nick;
        
        if(from) {
            _ignoreMask = [NSString stringWithFormat:@"%@!%@", from, _hostmask];
        }
    }
    return _ignoreMask;
}
@end

@implementation EventsDataSource
+(EventsDataSource *)sharedInstance {
    static EventsDataSource *sharedInstance;
	
    @synchronized(self) {
        if(!sharedInstance)
            sharedInstance = [[EventsDataSource alloc] init];
		
        return sharedInstance;
    }
	return nil;
}

-(id)init {
    self = [super init];
    _events = [[NSMutableDictionary alloc] init];
    _events_sorted = [[NSMutableDictionary alloc] init];
    _highestEid = 0;
    _dirty = YES;
    return self;
}

-(void)clear {
    @synchronized(_events) {
        [_events removeAllObjects];
        [_events_sorted removeAllObjects];
        _highestEid = 0;
    }
}

-(void)addEvent:(Event *)event {
    @synchronized(_events) {
        NSMutableArray *events = [_events objectForKey:@(event.bid)];
        if(!events) {
            events = [[NSMutableArray alloc] init];
            [_events setObject:events forKey:@(event.bid)];
        }
        [events addObject:event];
        NSMutableDictionary *events_sorted = [_events_sorted objectForKey:@(event.bid)];
        if(!events_sorted) {
            events_sorted = [[NSMutableDictionary alloc] init];
            [_events_sorted setObject:events_sorted forKey:@(event.bid)];
        }
        [events_sorted setObject:event forKey:@(event.eid)];
        _dirty = YES;
    }
}

-(Event *)addJSONObject:(IRCCloudJSONObject *)object {
    Event *event = [self event:object.eid buffer:object.bid];
    if(!event) {
        event = [[Event alloc] init];
        event.bid = object.bid;
        event.eid = object.eid;
        [self addEvent: event];
    }
    _dirty = YES;
    
    event.cid = object.cid;
    event.bid = object.bid;
    event.eid = object.eid;
    event.type = object.type;
    event.msg = [object objectForKey:@"msg"];
    event.hostmask = [object objectForKey:@"hostmask"];
    event.from = [object objectForKey:@"from"];
    event.fromMode = [object objectForKey:@"from_mode"];
    if([object objectForKey:@"newnick"])
        event.nick = [object objectForKey:@"newnick"];
    else
        event.nick = [object objectForKey:@"nick"];
    event.oldNick = [object objectForKey:@"oldnick"];
    event.server = [object objectForKey:@"server"];
    event.diff = [object objectForKey:@"diff"];
    event.isHighlight = [[object objectForKey:@"highlight"] boolValue];
    event.isSelf = [[object objectForKey:@"self"] boolValue];
    event.toChan = [[object objectForKey:@"to_chan"] boolValue];
    event.ops = [object objectForKey:@"ops"];
    event.chan = [object objectForKey:@"chan"];
    if([object objectForKey:@"reqid"])
        event.reqId = [[object objectForKey:@"reqid"] intValue];
    else
        event.reqId = -1;
    event.color = [UIColor blackColor];
    event.bgColor = [UIColor whiteColor];
    event.rowType = 0;
    event.formatted = nil;
    event.formattedMsg = nil;
    event.groupMsg = nil;
    event.linkify = YES;
    event.targetMode = nil;
    event.pending = NO;
    event.monospace = NO;
    
    if([object.type isEqualToString:@"socket_closed"]) {
        event.from = @"";
        event.rowType = ROW_SOCKETCLOSED;
        event.color = [UIColor timestampColor];
        if([object objectForKey:@"pool_lost"])
            event.msg = @"Connection pool lost";
        else if([object objectForKey:@"server_ping_timeout"])
            event.msg = @"Server PING timed out";
        else if([object objectForKey:@"reason"] && [[object objectForKey:@"reason"] length] > 0)
            event.msg = [NSString stringWithFormat:@"Connection lost: %@", [object objectForKey:@"reason"]];
        else if([object objectForKey:@"abnormal"])
            event.msg = @"Connection closed unexpectedly";
        else
            event.msg = @"";
    } else if([object.type isEqualToString:@"user_channel_mode"]) {
        event.targetMode = [object objectForKey:@"newmode"];
        event.chan = [object objectForKey:@"channel"];
    } else if([object.type isEqualToString:@"buffer_me_msg"]) {
        event.nick = event.from;
        event.from = @"";
    } else if([object.type isEqualToString:@"too_fast"]) {
        event.from = @"";
        event.bgColor = [UIColor errorBackgroundColor];
    } else if([object.type isEqualToString:@"no_bots"]) {
        event.from = @"";
        event.bgColor = [UIColor errorBackgroundColor];
    } else if([object.type isEqualToString:@"nickname_in_use"]) {
        event.from = [object objectForKey:@"nick"];
        event.msg = @"is already in use";
        event.bgColor = [UIColor errorBackgroundColor];
    } else if([object.type isEqualToString:@"unhandled_line"] || [object.type isEqualToString:@"unparsed_line"]) {
        event.from = @"";
        event.msg = @"";
        if([object objectForKey:@"command"])
            event.msg = [[object objectForKey:@"command"] stringByAppendingString:@" "];
        if([object objectForKey:@"raw"])
            event.msg = [event.msg stringByAppendingString:[object objectForKey:@"raw"]];
        else
            event.msg = [event.msg stringByAppendingString:[object objectForKey:@"msg"]];
        event.bgColor = [UIColor errorBackgroundColor];
    } else if([object.type isEqualToString:@"connecting_cancelled"]) {
        event.from = @"";
        event.msg = @"Cancelled";
        event.bgColor = [UIColor errorBackgroundColor];
    } else if([object.type isEqualToString:@"msg_services"]) {
        event.from = @"";
        event.bgColor = [UIColor errorBackgroundColor];
    } else if([object.type isEqualToString:@"connecting_failed"]) {
        event.rowType = ROW_SOCKETCLOSED;
        event.color = [UIColor timestampColor];
        event.from = @"";
        NSString *reason = [object objectForKey:@"reason"];
        if([reason isKindOfClass:[NSString class]] && [reason length]) {
            if([reason isEqualToString:@"pool_lost"])
                reason = @"Connection pool failed";
            else if([reason isEqualToString:@"no_pool"])
                reason = @"No available connection pools";
            else if([reason isEqualToString:@"enetdown"])
                reason = @"Network down";
            else if([reason isEqualToString:@"etimedout"] || [reason isEqualToString:@"timeout"])
                reason = @"Timed out";
            else if([reason isEqualToString:@"ehostunreach"])
                reason = @"Host unreachable";
            else if([reason isEqualToString:@"econnrefused"])
                reason = @"Connection refused";
            else if([reason isEqualToString:@"nxdomain"])
                reason = @"Invalid hostname";
            else if([reason isEqualToString:@"server_ping_timeout"])
                reason = @"PING timeout";
            else if([reason isEqualToString:@"ssl_certificate_error"])
                reason = @"SSL certificate error";
            else if([reason isEqualToString:@"ssl_error"])
                reason = @"SSL error";
            else if([reason isEqualToString:@"crash"])
                reason = @"Connection crashed";
            event.msg = [@"Failed to connect: " stringByAppendingString:reason];
        } else {
            event.msg = @"Failed to connect.";
        }
    } else if([object.type isEqualToString:@"quit_server"]) {
        event.from = @"";
        event.msg = @"⇐ You disconnected";
        event.color = [UIColor timestampColor];
    } else if([object.type isEqualToString:@"self_details"]) {
        event.from = @"";
        event.msg = [NSString stringWithFormat:@"Your hostmask: %c%@%c", BOLD, [object objectForKey:@"usermask"], BOLD];
        event.bgColor = [UIColor statusBackgroundColor];
        event.linkify = NO;
    } else if([object.type isEqualToString:@"myinfo"]) {
        event.from = @"";
        event.msg = [NSString stringWithFormat:@"Host: %@\n", [object objectForKey:@"server"]];
        event.msg = [event.msg stringByAppendingFormat:@"IRCd: %@\n", [object objectForKey:@"version"]];
        event.msg = [event.msg stringByAppendingFormat:@"User modes: %@\n", [object objectForKey:@"user_modes"]];
        event.msg = [event.msg stringByAppendingFormat:@"Channel modes: %@\n", [object objectForKey:@"channel_modes"]];
        event.bgColor = [UIColor statusBackgroundColor];
        event.linkify = NO;
    } else if([object.type isEqualToString:@"wait"]) {
        event.from = @"";
        event.bgColor = [UIColor statusBackgroundColor];
    } else if([object.type isEqualToString:@"user_mode"]) {
        event.from = @"";
        event.msg = [NSString stringWithFormat:@"Your user mode is: %c+%@%c", BOLD, [object objectForKey:@"newmode"], BOLD];
        event.bgColor = [UIColor statusBackgroundColor];
    } else if([object.type isEqualToString:@"your_unique_id"]) {
        event.from = @"";
        event.msg = [NSString stringWithFormat:@"Your unique ID is: %c%@%c", BOLD, [object objectForKey:@"unique_id"], BOLD];
        event.bgColor = [UIColor statusBackgroundColor];
    } else if([event.type hasPrefix:@"stats"]) {
        event.from = @"";
        if([object objectForKey:@"parts"] && [[object objectForKey:@"parts"] length] > 0)
            event.msg = [NSString stringWithFormat:@"%@: %@", [object objectForKey:@"parts"], event.msg];
        event.bgColor = [UIColor statusBackgroundColor];
        event.linkify = NO;
    } else if([object.type isEqualToString:@"endofstats"]) {
        event.from = @"";
        event.msg = [NSString stringWithFormat:@"%@: %@", [object objectForKey:@"parts"], event.msg];
        event.bgColor = [UIColor statusBackgroundColor];
    } else if([object.type isEqualToString:@"kill"]) {
        event.from = @"";
        event.msg = @"You were killed";
        if([object objectForKey:@"from"])
            event.msg = [event.msg stringByAppendingFormat:@" by %@", [object objectForKey:@"from"]];
        if([object objectForKey:@"killer_hostmask"])
            event.msg = [event.msg stringByAppendingFormat:@" (%@)", [object objectForKey:@"killer_hostmask"]];
        if([object objectForKey:@"reason"])
            event.msg = [event.msg stringByAppendingFormat:@": %@", [object objectForKey:@"reason"]];
        event.bgColor = [UIColor statusBackgroundColor];
        event.linkify = NO;
    } else if([object.type isEqualToString:@"banned"]) {
        event.from = @"";
        event.msg = @"You were banned";
        if([object objectForKey:@"server"])
            event.msg = [event.msg stringByAppendingFormat:@" from %@", [object objectForKey:@"server"]];
        if([object objectForKey:@"reason"])
            event.msg = [event.msg stringByAppendingFormat:@": %@", [object objectForKey:@"reason"]];
        event.bgColor = [UIColor statusBackgroundColor];
        event.linkify = NO;
    } else if([object.type isEqualToString:@"channel_topic"]) {
        event.from = [object objectForKey:@"author"];
        event.msg = [NSString stringWithFormat:@"set the topic: %@", [object objectForKey:@"topic"]];
        event.bgColor = [UIColor statusBackgroundColor];
    } else if([object.type isEqualToString:@"channel_mode"]) {
        event.nick = event.from;
        event.from = @"";
        event.msg = [NSString stringWithFormat:@"Channel mode set to: %c%@%c", BOLD, [object objectForKey:@"diff"], BOLD];
        event.bgColor = [UIColor statusBackgroundColor];
    } else if([object.type isEqualToString:@"channel_mode_is"]) {
        event.from = @"";
        if([[object objectForKey:@"diff"] length] > 0)
            event.msg = [NSString stringWithFormat:@"Channel mode is: %c%@%c", BOLD, [object objectForKey:@"diff"], BOLD];
        else
            event.msg = @"No channel mode";
        event.bgColor = [UIColor statusBackgroundColor];
    } else if([object.type isEqualToString:@"kicked_channel"] || [object.type isEqualToString:@"you_kicked_channel"]) {
        event.from = @"";
        event.fromMode = nil;
        event.oldNick = [object objectForKey:@"nick"];
        event.nick = [object objectForKey:@"kicker"];
        event.hostmask = [object objectForKey:@"kicker_hostmask"];
        event.color = [UIColor timestampColor];
        event.linkify = NO;
    } else if([object.type isEqualToString:@"channel_mode_list_change"]) {
        BOOL unknown = YES;
        NSDictionary *ops = [object objectForKey:@"ops"];
        if(ops) {
            NSArray *add = [ops objectForKey:@"add"];
            if(add.count > 0) {
                NSDictionary *op = [add objectAtIndex:0];
                if([[[op objectForKey:@"mode"] lowercaseString] isEqualToString:@"b"]) {
                    event.nick = event.from;
                    event.from = @"";
                    event.msg = [NSString stringWithFormat:@"Channel ban set for %c%@%c (+b) by ", BOLD, [op objectForKey:@"param"], BOLD];
                    unknown = NO;
                }
            }
            NSArray *remove = [ops objectForKey:@"remove"];
            if(remove.count > 0) {
                NSDictionary *op = [remove objectAtIndex:0];
                if([[[op objectForKey:@"mode"] lowercaseString] isEqualToString:@"b"]) {
                    event.nick = event.from;
                    event.from = @"";
                    event.msg = [NSString stringWithFormat:@"Channel ban removed for %c%@%c (-b) by ", BOLD, [op objectForKey:@"param"], BOLD];
                    unknown = NO;
                }
            }
        }
        if(unknown) {
            event.nick = event.from;
            event.from = @"";
            event.msg = [NSString stringWithFormat:@"Channel mode set to %c%@%c by ", BOLD, [object objectForKey:@"diff"], BOLD];
        }
        event.bgColor = [UIColor statusBackgroundColor];
        event.linkify = NO;
    } else if([object.type isEqualToString:@"motd_response"] || [object.type isEqualToString:@"server_motd"]) {
        NSArray *lines = [object objectForKey:@"lines"];
        event.from = @"";
        if([lines count]) {
            if([[object objectForKey:@"start"] length])
                event.msg = [[object objectForKey:@"start"] stringByAppendingString:@"\n"];
            else
                event.msg = @"";
            
            for(NSString *line in lines) {
                event.msg = [event.msg stringByAppendingFormat:@"%@\n", line];
            }
        }
        event.bgColor = [UIColor selfBackgroundColor];
        event.monospace = YES;
    } else if([object.type isEqualToString:@"notice"]) {
        event.bgColor = [UIColor noticeBackgroundColor];
        event.monospace = YES;
    } else if([object.type hasPrefix:@"hidden_host_set"]) {
        event.bgColor = [UIColor statusBackgroundColor];
        event.linkify = NO;
        event.from = @"";
        event.msg = [NSString stringWithFormat:@"%c%@%c %@", BOLD, [object objectForKey:@"hidden_host"], BOLD, event.msg];
    } else if([object.type hasPrefix:@"server_nomotd"]) {
        event.linkify = NO;
        event.from = @"";
        event.color = [UIColor timestampColor];
    } else if([object.type hasPrefix:@"server_"]) {
        event.bgColor = [UIColor statusBackgroundColor];
        event.linkify = NO;
    } else if([object.type isEqualToString:@"inviting_to_channel"]) {
        event.from = @"";
        event.msg = [NSString stringWithFormat:@"You invited %@ to join %@", [object objectForKey:@"recipient"], [object objectForKey:@"channel"]];
        event.bgColor = [UIColor noticeBackgroundColor];
    } else if([object.type isEqualToString:@"channel_invite"]) {
        event.msg = [NSString stringWithFormat:@"Invite to join %@", [object objectForKey:@"channel"]];
        event.oldNick = [object objectForKey:@"channel"];
        event.bgColor = [UIColor noticeBackgroundColor];
        event.monospace = YES;
    } else if([object.type isEqualToString:@"callerid"]) {
        event.msg = [event.msg stringByAppendingFormat:@" Tap to add %c%@%c to the whitelist.", BOLD, event.nick, CLEAR];
        event.from = event.nick;
        event.isHighlight = YES;
        event.linkify = NO;
        event.monospace = YES;
        event.hostmask = [object objectForKey:@"usermask"];
    } else if([object.type isEqualToString:@"target_callerid"]) {
        event.from = [object objectForKey:@"target_nick"];
        event.bgColor = [UIColor errorBackgroundColor];
        event.monospace = YES;
    } else if([object.type isEqualToString:@"target_notified"]) {
        event.from = [object objectForKey:@"target_nick"];
        event.bgColor = [UIColor errorBackgroundColor];
        event.monospace = YES;
    } else if([object.type isEqualToString:@"link_channel"]) {
        event.from = @"";
        event.msg = [NSString stringWithFormat:@"You tried to join %@ but were forwarded to %@", [object objectForKey:@"invalid_chan"], [object objectForKey:@"valid_chan"]];
        event.bgColor = [UIColor errorBackgroundColor];
        event.monospace = YES;
    }
                  
    if([object objectForKey:@"value"]) {
        event.msg = [NSString stringWithFormat:@"%@ %@", [object objectForKey:@"value"], event.msg];
    }

    if(event.isHighlight)
        event.bgColor = [UIColor highlightBackgroundColor];

    if(event.isSelf)
        event.bgColor = [UIColor selfBackgroundColor];
    
    if(event.eid > _highestEid)
        _highestEid = event.eid;
    
    return event;
}

-(Event *)event:(NSTimeInterval)eid buffer:(int)bid {
    @synchronized(_events) {
        return [[_events_sorted objectForKey:@(bid)] objectForKey:@(eid)];
    }
}

-(void)removeEvent:(NSTimeInterval)eid buffer:(int)bid {
    @synchronized(_events) {
        for(Event *event in [_events objectForKey:@(bid)]) {
            if(event.eid == eid) {
                [[_events objectForKey:@(bid)] removeObject:event];
                [[_events_sorted objectForKey:@(bid)] removeObjectForKey:@(eid)];
                break;
            }
        }
        _dirty = YES;
    }
}

-(void)removeEventsForBuffer:(int)bid {
    @synchronized(_events) {
        [_events removeObjectForKey:@(bid)];
        [_events_sorted removeObjectForKey:@(bid)];
    }
}

-(NSArray *)eventsForBuffer:(int)bid {
    @synchronized(_events) {
        if(_dirty) {
            [[_events objectForKey:@(bid)] sortUsingSelector:@selector(compare:)];
            _dirty = NO;
        }
        return [NSArray arrayWithArray:[_events objectForKey:@(bid)]];
    }
}

-(void)removeEventsBefore:(NSTimeInterval)min_eid buffer:(int)bid {
    @synchronized(_events) {
        NSMutableArray *eventsToRemove = [[NSMutableArray alloc] init];
        for(Event *event in [_events objectForKey:@(bid)]) {
            if(event.eid < min_eid) {
                [eventsToRemove addObject:event];
            }
        }
        for(Event *event in eventsToRemove) {
            [[_events objectForKey:@(bid)] removeObject:event];
            [[_events_sorted objectForKey:@(bid)] removeObjectForKey:@(event.eid)];
        }
    }
}

-(int)unreadCountForBuffer:(int)bid lastSeenEid:(NSTimeInterval)lastSeenEid type:(NSString *)type {
    int count = 0;
    Buffer *b = [[BuffersDataSource sharedInstance] getBuffer:bid];
    Server *s = [[ServersDataSource sharedInstance] getServer:b.cid];
    Ignore *ignore = [[Ignore alloc] init];
    [ignore setIgnores:s.ignores];
    NSArray *copy;
    @synchronized(_events) {
        copy = [NSArray arrayWithArray:[_events objectForKey:@(bid)]];
    }
    for(Event *event in copy) {
        if(event.eid > lastSeenEid && [event isImportant:type]) {
            if(event.ignoreMask && [ignore match:event.ignoreMask])
                continue;
            count++;
        }
    }
    return count;
}

-(int)highlightCountForBuffer:(int)bid lastSeenEid:(NSTimeInterval)lastSeenEid type:(NSString *)type {
    int count = 0;
    Buffer *b = [[BuffersDataSource sharedInstance] getBuffer:bid];
    Server *s = [[ServersDataSource sharedInstance] getServer:b.cid];
    Ignore *ignore = [[Ignore alloc] init];
    [ignore setIgnores:s.ignores];
    NSArray *copy;
    @synchronized(_events) {
        copy = [NSArray arrayWithArray:[_events objectForKey:@(bid)]];
    }
    for(Event *event in copy) {
        if(event.eid > lastSeenEid && [event isImportant:type] && (event.isHighlight || [type isEqualToString:@"conversation"])) {
            if(event.ignoreMask && [ignore match:event.ignoreMask])
                continue;
            count++;
        }
    }
    return count;
}

@end
