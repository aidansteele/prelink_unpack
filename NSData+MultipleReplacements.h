//
//  NSData+MultipleReplacements.h
//  prelink_unpack
//
//  Created by Aidan Steele on 5/11/10.
//  Copyright 2010 Glass Echidna. All rights reserved.
//

#import <Foundation/Foundation.h>

NSInteger rangeSort(id valueA, id valueB, void *context);

@interface NSMutableData (NSData_MultipleReplacements)

- (void)replaceBytesInRanges:(NSArray *)ranges withDatas:(NSArray *)datas;

@end
