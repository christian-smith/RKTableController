//
//  RKTableController.m
//  RestKit
//
//  Created by Blake Watters on 8/1/11.
//  Copyright (c) 2009-2012 RestKit. All rights reserved.
//
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
//

#import "RKTableController.h"
#import "RKAbstractTableController_Internals.h"
#import "RKLog.h"
#import "NSArray+RKAdditions.h"
#import "RKMappingOperation.h"
#import "RKMappingOperationDataSource.h"

// Define logging component
#undef RKLogComponent
#define RKLogComponent lcl_cRestKitUI

@interface RKTableController ()
@property (nonatomic, readwrite) NSMutableArray *sections;
@end

@implementation RKTableController

@dynamic delegate;
@synthesize sectionNameKeyPath = _sectionNameKeyPath;
@synthesize sections = _sections;

#pragma mark - Instantiation

- (id)init
{
    self = [super init];
    if (self) {
        _sections = [NSMutableArray new];
        [self addObserver:self
               forKeyPath:@"sections"
                  options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                  context:nil];

        RKTableSection *section = [RKTableSection section];
        [self addSection:section];
    }

    return self;
}

- (void)dealloc
{
    [self removeObserver:self forKeyPath:@"sections"];

}

#pragma mark - Managing Sections

// KVO-compliant proxy object for section mutations
- (NSMutableArray *)sectionsProxy
{
    return [self mutableArrayValueForKey:@"sections"];
}

- (void)addSectionsObject:(id)section
{
    [self.sections addObject:section];
}

- (void)insertSections:(NSArray *)objects atIndexes:(NSIndexSet *)indexes
{
    [self.sections insertObjects:objects atIndexes:indexes];
}

- (void)removeSectionsAtIndexes:(NSIndexSet *)indexes
{
    [self.sections removeObjectsAtIndexes:indexes];
}

- (void)replaceSectionsAtIndexes:(NSIndexSet *)indexes withObjects:(NSArray *)objects
{
    [self.sections replaceObjectsAtIndexes:indexes withObjects:objects];
}

- (void)addSection:(RKTableSection *)section
{
    NSAssert(section, @"Cannot insert a nil section");
    section.tableController = self;
    if (! section.cellMappings) {
        section.cellMappings = self.cellMappings;
    }

    [[self sectionsProxy] addObject:section];
}

- (void)removeSection:(RKTableSection *)section
{
    NSAssert(section, @"Cannot remove a nil section");
    if ([self.sections containsObject:section] && self.sectionCount == 1) {
        @throw [NSException exceptionWithName:NSInvalidArgumentException
                                       reason:@"Tables must always have at least one section"
                                     userInfo:nil];
    }
    [[self sectionsProxy] removeObject:section];
}

- (void)insertSection:(RKTableSection *)section atIndex:(NSUInteger)index
{
    NSAssert(section, @"Cannot insert a nil section");
    section.tableController = self;
    [[self sectionsProxy] insertObject:section atIndex:index];
}

- (void)removeSectionAtIndex:(NSUInteger)index
{
    if (index < self.sectionCount && self.sectionCount == 1) {
        @throw [NSException exceptionWithName:NSInvalidArgumentException
                                       reason:@"Tables must always have at least one section"
                                     userInfo:nil];
    }
    [[self sectionsProxy] removeObjectAtIndex:index];
}

- (void)removeAllSections:(BOOL)recreateFirstSection
{
    [[self sectionsProxy] removeAllObjects];

    if (recreateFirstSection) {
        [self addSection:[RKTableSection section]];
    }
}

- (void)removeAllSections
{
    [self removeAllSections:YES];
}

- (void)updateTableViewUsingBlock:(void (^)())block
{
    [self.tableView beginUpdates];
    block();
    [self.tableView endUpdates];
}

#pragma mark - Static Tables

- (NSArray *)objectsWithHeaderAndFooters:(NSArray *)objects forSection:(NSUInteger)sectionIndex
{
    NSMutableArray *mutableObjects = [objects mutableCopy];
    if (sectionIndex == 0) {
        if ([self.headerItems count] > 0) {
            [mutableObjects insertObjects:self.headerItems atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.headerItems.count)]];
        }
        if (self.emptyItem) {
            [mutableObjects insertObject:self.emptyItem atIndex:0];
        }
    }

    if (sectionIndex == (self.sectionCount - 1) && [self.footerItems count] > 0) {
        [mutableObjects addObjectsFromArray:self.footerItems];
    }

    return mutableObjects;
}

// NOTE - Everything currently needs to pass through this method to pick up header/footer rows...
- (void)loadObjects:(NSArray *)objects inSection:(NSUInteger)sectionIndex
{
    // Clear any existing error state from the table
    self.error = nil;

    RKTableSection *section = [self sectionAtIndex:sectionIndex];
    section.objects = [self objectsWithHeaderAndFooters:objects forSection:sectionIndex];
    for (NSUInteger index = 0; index < [section.objects count]; index++) {
        if ([self.delegate respondsToSelector:@selector(tableController:didInsertObject:atIndexPath:)]) {
            [self.delegate tableController:self
                          didInsertObject:[section objectAtIndex:index]
                              atIndexPath:[NSIndexPath indexPathForRow:index inSection:sectionIndex]];
        }
    }

    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:sectionIndex] withRowAnimation:self.defaultRowAnimation];

    if ([self.delegate respondsToSelector:@selector(tableController:didLoadObjects:inSection:)]) {
        [self.delegate tableController:self didLoadObjects:objects inSection:section];
    }

    // The load is finalized via network callbacks for
    // dynamic table controllers
    if (nil == self.objectRequestOperation) {
        [self didFinishLoad];
    }
}

- (void)loadObjects:(NSArray *)objects
{
    [self loadObjects:objects inSection:0];
}

- (void)loadEmpty
{
    [self removeAllSections:YES];
    [self loadObjects:[NSArray array]];
}

- (void)loadTableItems:(NSArray *)tableItems inSection:(NSUInteger)sectionIndex
{
    for (RKTableItem *tableItem in tableItems) {
        if ([tableItem.cellMapping.attributeMappings count] == 0) {
            [tableItem.cellMapping addDefaultMappings];
        }
    }

    [self loadObjects:tableItems inSection:sectionIndex];
}

- (void)loadTableItems:(NSArray *)tableItems
             inSection:(NSUInteger)sectionIndex
             withMapping:(RKTableViewCellMapping *)cellMapping
{
    NSAssert(tableItems, @"Cannot load a nil collection of table items");
    NSAssert(sectionIndex < self.sectionCount, @"Cannot load table items into a section that does not exist");
    NSAssert(cellMapping, @"Cannot load table items without a cell mapping");
    for (RKTableItem *tableItem in tableItems) {
        tableItem.cellMapping = cellMapping;
    }
    [self loadTableItems:tableItems inSection:sectionIndex];
}

- (void)loadTableItems:(NSArray *)tableItems withMapping:(RKTableViewCellMapping *)cellMapping
{
    [self loadTableItems:tableItems inSection:0 withMapping:cellMapping];
}

- (void)loadTableItems:(NSArray *)tableItems
{
    [self loadTableItems:tableItems inSection:0];
}

#pragma mark - UITableViewDataSource methods

- (void)tableView:(UITableView *)theTableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSAssert(theTableView == self.tableView, @"tableView:commitEditingStyle:forRowAtIndexPath: invoked with inappropriate tableView: %@", theTableView);
    if (self.canEditRows) {
        if (editingStyle == UITableViewCellEditingStyleDelete) {
            RKTableSection *section = [self.sections objectAtIndex:indexPath.section];
            [section removeObjectAtIndex:indexPath.row];

        } else if (editingStyle == UITableViewCellEditingStyleInsert) {
            // TODO: Anything we need to do here, since we do not have the object to insert?
        }
    }
}

- (void)tableView:(UITableView *)theTableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destIndexPath
{
    NSAssert(theTableView == self.tableView, @"tableView:moveRowAtIndexPath:toIndexPath: invoked with inappropriate tableView: %@", theTableView);
    if (self.canMoveRows) {
        if (sourceIndexPath.section == destIndexPath.section) {
            RKTableSection *section = [self.sections objectAtIndex:sourceIndexPath.section];
            [section moveObjectAtIndex:sourceIndexPath.row toIndex:destIndexPath.row];

        } else {
            [self.tableView beginUpdates];
            RKTableSection *sourceSection = [self.sections objectAtIndex:sourceIndexPath.section];
            id object = [sourceSection objectAtIndex:sourceIndexPath.row];
            [sourceSection removeObjectAtIndex:sourceIndexPath.row];

            RKTableSection *destinationSection = nil;
            if (destIndexPath.section < [self sectionCount]) {
                destinationSection = [self.sections objectAtIndex:destIndexPath.section];
            } else {
                destinationSection = [RKTableSection section];
                [self insertSection:destinationSection atIndex:destIndexPath.section];
            }
            [destinationSection insertObject:object atIndex:destIndexPath.row];
            [self.tableView endUpdates];
        }
    }
}

#pragma mark - RKRequestDelegate & RKObjectLoaderDelegate methods

- (void)didLoadObjects:(NSArray *)objects
{
    // TODO: Could not get the KVO to work without a boolean property...
    // TODO: Apply any sorting...
    
    if (self.sectionNameKeyPath) {
        NSArray *sectionedObjects = [objects sectionsGroupedByKeyPath:self.sectionNameKeyPath];
        if ([sectionedObjects count] == 0) {
            [self removeAllSections];
        }
        for (NSArray *sectionOfObjects in sectionedObjects) {
            NSUInteger sectionIndex = [sectionedObjects indexOfObject:sectionOfObjects];
            if (sectionIndex >= [self sectionCount]) {
                [self addSection:[RKTableSection section]];
            }
            [self loadObjects:sectionOfObjects inSection:sectionIndex];
        }
    } else {
        [self loadObjects:objects inSection:0];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    if ([keyPath isEqualToString:@"sections"]) {
        // No table view to inform...
        if (! self.tableView) {
            return;
        }

        NSIndexSet *changedSectionIndexes = [change objectForKey:NSKeyValueChangeIndexesKey];
        NSAssert(changedSectionIndexes, @"Received a KVO notification for settings property without an NSKeyValueChangeIndexesKey");
        if ([[change objectForKey:NSKeyValueChangeKindKey] intValue] == NSKeyValueChangeInsertion) {
            // Section(s) Inserted
            [self.tableView insertSections:changedSectionIndexes withRowAnimation:self.defaultRowAnimation];

            // TODO: Add observers on the sections objects...

        } else if ([[change objectForKey:NSKeyValueChangeKindKey] intValue] == NSKeyValueChangeRemoval) {
            // Section(s) Deleted
            [self.tableView deleteSections:changedSectionIndexes withRowAnimation:self.defaultRowAnimation];

            // TODO: Remove observers on the sections objects...
        } else if ([[change objectForKey:NSKeyValueChangeKindKey] intValue] == NSKeyValueChangeReplacement) {
            // Section(s) Replaced
            [self.tableView reloadSections:changedSectionIndexes withRowAnimation:self.defaultRowAnimation];

            // TODO: Remove observers on the sections objects...
        }
    }

    // TODO: KVO should be used for managing the row level manipulations on the table view as well...
}

#pragma mark - Managing Sections

- (NSUInteger)sectionCount
{
    return [_sections count];
}

- (NSUInteger)rowCount
{
    return [[_sections valueForKeyPath:@"@sum.rowCount"] intValue];
}

- (RKTableSection *)sectionAtIndex:(NSUInteger)index
{
    return [_sections objectAtIndex:index];
}

- (NSUInteger)indexForSection:(RKTableSection *)section
{
    NSAssert(section, @"Cannot return index for a nil section");
    return [_sections indexOfObject:section];
}

- (RKTableSection *)sectionWithHeaderTitle:(NSString *)title
{
    for (RKTableSection *section in _sections) {
        if ([section.headerTitle isEqualToString:title]) {
            return section;
        }
    }

    return nil;
}

- (NSUInteger)numberOfRowsInSection:(NSUInteger)index
{
    return [self sectionAtIndex:index].rowCount;
}

#pragma mark - Cell Mappings

- (id)objectForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSAssert(indexPath, @"Cannot lookup object with a nil indexPath");
    RKTableSection *section = [self sectionAtIndex:indexPath.section];
    return [section objectAtIndex:indexPath.row];
}


#pragma mark = UIScrollViewDelegate pass through methods

- (BOOL)respondsToSelector:(SEL)aSelector
{
    if (sel_isEqual(aSelector, @selector(scrollViewDidScroll:))) {
        return [self.viewController respondsToSelector:@selector(scrollViewWillBeginDragging:)];
    } else if (sel_isEqual(aSelector, @selector(scrollViewWillBeginDragging:))) {
        return [self.viewController respondsToSelector:@selector(scrollViewWillBeginDragging:)];
    } else if (sel_isEqual(aSelector, @selector(scrollViewWillEndDragging:withVelocity:targetContentOffset:))) {
        return [self.viewController respondsToSelector:@selector(scrollViewWillEndDragging:withVelocity:targetContentOffset:)];
    } else if (sel_isEqual(aSelector, @selector(scrollViewDidEndDragging:willDecelerate:))) {
        return [self.viewController respondsToSelector:@selector(scrollViewDidEndDragging:willDecelerate:)];
    } else if (sel_isEqual(aSelector, @selector(scrollViewShouldScrollToTop:))) {
        return [self.viewController respondsToSelector:@selector(scrollViewShouldScrollToTop:)];
    } else if (sel_isEqual(aSelector, @selector(scrollViewDidScrollToTop:))) {
        return [self.viewController respondsToSelector:@selector(scrollViewDidScrollToTop:)];
    } else if (sel_isEqual(aSelector, @selector(scrollViewWillBeginDecelerating:))) {
        return [self.viewController respondsToSelector:@selector(scrollViewWillBeginDecelerating:)];
    } else if (sel_isEqual(aSelector, @selector(scrollViewDidEndDecelerating:))) {
        return [self.viewController respondsToSelector:@selector(scrollViewDidEndDecelerating:)];
    } else if (sel_isEqual(aSelector, @selector(scrollViewDidEndScrollingAnimation:))) {
        return [self.viewController respondsToSelector:@selector(scrollViewDidEndScrollingAnimation:)];
    } else {
        return [super respondsToSelector:aSelector];
    }
}


- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    if ([self.viewController respondsToSelector:@selector(scrollViewDidScroll:)]) {
        [((id)self.viewController) scrollViewDidScroll:scrollView];
    }
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    if ([self.viewController respondsToSelector:@selector(scrollViewWillBeginDragging:)]) {
        [((id)self.viewController) scrollViewWillBeginDragging:scrollView];
    }
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset
{
    if ([self.viewController respondsToSelector:@selector(scrollViewWillEndDragging:withVelocity:targetContentOffset:)]) {
        [((id)self.viewController) scrollViewWillEndDragging:scrollView withVelocity:velocity targetContentOffset:targetContentOffset];
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    if ([self.viewController respondsToSelector:@selector(scrollViewDidEndDragging:willDecelerate:)]) {
        [((id)self.viewController) scrollViewDidEndDragging:scrollView willDecelerate:decelerate];
    }
}

- (BOOL)scrollViewShouldScrollToTop:(UIScrollView *)scrollView
{
    if ([self.viewController respondsToSelector:@selector(scrollViewShouldScrollToTop:)]) {
        [((id)self.viewController) scrollViewShouldScrollToTop:scrollView];
    }
}

- (void)scrollViewDidScrollToTop:(UIScrollView *)scrollView
{
    if ([self.viewController respondsToSelector:@selector(scrollViewDidScrollToTop:)]) {
        [((id)self.viewController) scrollViewDidScrollToTop:scrollView];
    }
}

- (void)scrollViewWillBeginDecelerating:(UIScrollView *)scrollView
{
    if ([self.viewController respondsToSelector:@selector(scrollViewWillBeginDecelerating:)]) {
        [((id)self.viewController) scrollViewWillBeginDecelerating:scrollView];
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    if ([self.viewController respondsToSelector:@selector(scrollViewDidEndDecelerating:)]) {
        [((id)self.viewController) scrollViewDidEndDecelerating:scrollView];
    }
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView
{
    if ([self.viewController respondsToSelector:@selector(scrollViewDidEndScrollingAnimation:)]) {
        [((id)self.viewController) scrollViewDidEndScrollingAnimation:scrollView];
    }
}


#pragma mark - UITableViewDataSource methods

- (NSString *)tableView:(UITableView *)theTableView titleForHeaderInSection:(NSInteger)section
{
    NSAssert(theTableView == self.tableView, @"tableView:titleForHeaderInSection: invoked with inappropriate tableView: %@", theTableView);
    return [[_sections objectAtIndex:section] headerTitle];
}

- (NSString *)tableView:(UITableView *)theTableView titleForFooterInSection:(NSInteger)section
{
    NSAssert(theTableView == self.tableView, @"tableView:titleForFooterInSection: invoked with inappropriate tableView: %@", theTableView);
    return [[_sections objectAtIndex:section] footerTitle];
}

- (BOOL)tableView:(UITableView *)theTableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSAssert(theTableView == self.tableView, @"tableView:canEditRowAtIndexPath: invoked with inappropriate tableView: %@", theTableView);
    return self.canEditRows;
}

- (BOOL)tableView:(UITableView *)theTableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSAssert(theTableView == self.tableView, @"tableView:canMoveRowAtIndexPath: invoked with inappropriate tableView: %@", theTableView);
    return self.canMoveRows;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)theTableView
{
    NSAssert(theTableView == self.tableView, @"numberOfSectionsInTableView: invoked with inappropriate tableView: %@", theTableView);
    RKLogTrace(@"%@ numberOfSectionsInTableView = %d", self, self.sectionCount);
    return self.sectionCount;
}

- (NSInteger)tableView:(UITableView *)theTableView numberOfRowsInSection:(NSInteger)section
{
    NSAssert(theTableView == self.tableView, @"tableView:numberOfRowsInSection: invoked with inappropriate tableView: %@", theTableView);
    RKLogTrace(@"%@ numberOfRowsInSection:%d = %d", self, section, self.sectionCount);
    return [[_sections objectAtIndex:section] rowCount];
}

- (NSIndexPath *)indexPathForObject:(id)object
{
    NSUInteger sectionIndex = 0;
    for (RKTableSection *section in self.sections) {
        NSUInteger rowIndex = 0;
        for (id rowObject in section.objects) {
            if ([rowObject isEqual:object]) {
                return [NSIndexPath indexPathForRow:rowIndex inSection:sectionIndex];
            }

            rowIndex++;
        }
        sectionIndex++;
    }

    return nil;
}

- (CGFloat)tableView:(UITableView *)theTableView heightForHeaderInSection:(NSInteger)sectionIndex
{
    NSAssert(theTableView == self.tableView, @"heightForHeaderInSection: invoked with inappropriate tableView: %@", theTableView);
    if ([self.delegate respondsToSelector:@selector(tableController:heightForHeaderInSection:)]) {
        return [self.delegate tableController:self heightForHeaderInSection:sectionIndex];
    } else {
        RKTableSection *section = [self sectionAtIndex:sectionIndex];
        return section.headerHeight;
    }
}

- (CGFloat)tableView:(UITableView *)theTableView heightForFooterInSection:(NSInteger)sectionIndex
{
    NSAssert(theTableView == self.tableView, @"heightForFooterInSection: invoked with inappropriate tableView: %@", theTableView);
    if ([self.delegate respondsToSelector:@selector(tableController:heightForFooterInSection:)]) {
        return [self.delegate tableController:self heightForFooterInSection:sectionIndex];
    } else {
        RKTableSection *section = [self sectionAtIndex:sectionIndex];
        return section.footerHeight;
    }
}

- (UIView *)tableView:(UITableView *)theTableView viewForHeaderInSection:(NSInteger)sectionIndex
{
    NSAssert(theTableView == self.tableView, @"viewForHeaderInSection: invoked with inappropriate tableView: %@", theTableView);
    RKTableSection *section = [self sectionAtIndex:sectionIndex];
    return section.headerView;
}

- (UIView *)tableView:(UITableView *)theTableView viewForFooterInSection:(NSInteger)sectionIndex
{
    NSAssert(theTableView == self.tableView, @"viewForFooterInSection: invoked with inappropriate tableView: %@", theTableView);
    RKTableSection *section = [self sectionAtIndex:sectionIndex];
    return section.footerView;
}

- (BOOL)isConsideredEmpty
{
    NSUInteger nonRowItemsCount = [self.headerItems count] + [self.footerItems count];
    nonRowItemsCount += self.emptyItem ? 1 : 0;
    BOOL isEmpty = (self.rowCount - nonRowItemsCount) == 0;
    RKLogTrace(@"Determined isConsideredEmpty = %@. self.rowCount = %d with %d nonRowItems in the table", isEmpty ? @"YES" : @"NO", self.rowCount, nonRowItemsCount);
    return isEmpty;
}

- (void)pullToRefreshStateChanged:(UIGestureRecognizer *)gesture
{
    if (gesture.state == UIGestureRecognizerStateRecognized) {
        if ([self pullToRefreshDataSourceIsLoading:gesture]) return;
        RKLogDebug(@"%@: pull to refresh triggered from gesture: %@", self, gesture);
        [self loadTableWithRequest:self.request];
    }
}

@end
