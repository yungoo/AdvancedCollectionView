/*
 Copyright (C) 2014 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information
 
 Abstract:
 
  A UICollectionViewLayout subclass that works with AAPLDataSource instances to render content in a manner similar to UITableView but with such additional features as multiple columns, pinning headers, and placeholder views.
  
 */

#import "AAPLCollectionViewGridLayout_Internal.h"
#import "AAPLLayoutMetrics_Private.h"
#import "AAPLDataSource.h"
#import "AAPLCollectionViewGridLayoutAttributes_Private.h"
#import "UICollectionView+Helpers.h"
#import "AAPLMath.h"
#import "UIView+Helpers.h"
#import "AAPLGridLayoutColorView.h"

/// Supporting "global" index paths
NS_INLINE NSUInteger globalIndexPathSection(NSIndexPath *indexPath) {
    if (indexPath.length == 1) {
        return NSNotFound;
    }
    return [indexPath indexAtPosition:0];
}

NS_INLINE NSUInteger globalIndexPathItem(NSIndexPath *indexPath) {
    if (indexPath.length == 1) {
        return [indexPath indexAtPosition:0];
    }
    return [indexPath indexAtPosition:1];
}

static inline NSString *__unused AAPLStringFromBOOL(BOOL value)
{
    return value ? @"YES" : @"NO";
}

static inline NSString *__unused AAPLStringFromNSIndexPath(NSIndexPath *indexPath)
{
    NSMutableArray *indexes = [NSMutableArray array];
    NSUInteger numberOfIndexes = indexPath.length;

    for (NSUInteger currentIndex = 0; currentIndex < numberOfIndexes; ++ currentIndex)
        [indexes addObject:@([indexPath indexAtPosition:currentIndex])];

    return [NSString stringWithFormat:@"(%@)", [indexes componentsJoinedByString:@", "]];
}

#define LAYOUT_DEBUGGING 1
#define LAYOUT_LOGGING 1

#if LAYOUT_DEBUGGING
#define LAYOUT_LOGGING 1
#endif

#if LAYOUT_LOGGING
#define LAYOUT_TRACE() NSLog(@"%@", NSStringFromSelector(_cmd))
#define LAYOUT_LOG(FORMAT, ...) NSLog(@"%@ " FORMAT, NSStringFromSelector(_cmd), __VA_ARGS__)
#else
#define LAYOUT_TRACE()
#define LAYOUT_LOG(...)
#endif


#define DRAG_SHADOW_HEIGHT 19

#define SCROLL_SPEED_MAX_MULTIPLIER 4.0
#define FRAMES_PER_SECOND 60.0

#define DEFAULT_ZINDEX 1
#define SEPARATOR_ZINDEX 100
#define HEADER_ZINDEX 1000
#define PINNED_HEADER_ZINDEX 10000

static NSString * const AAPLGridLayoutRowSeparatorKind = @"AAPLGridLayoutRowSeparatorKind";
static NSString * const AAPLGridLayoutColumnSeparatorKind = @"AAPLGridLayoutColumnSeparatorKind";
static NSString * const AAPLGridLayoutHeaderSeparatorKind = @"headerSeparator";
static NSString * const AAPLGridLayoutFooterSeparatorKind = @"footerSeparator";
static NSString * const AAPLGridLayoutGlobalHeaderBackgroundKind = @"AAPLGridLayoutGlobalHeaderBackgroundKind";

static inline CGPoint AAPLPointAddPoint(CGPoint point1, CGPoint point2)
{
    return CGPointMake(point1.x + point2.x, point1.y + point2.y);
}

typedef NS_ENUM(NSInteger, AAPLAutoScrollDirection) {
    AAPLAutoScrollDirectionUnknown = 0,
    AAPLAutoScrollDirectionUp,
    AAPLAutoScrollDirectionDown,
    AAPLAutoScrollDirectionLeft,
    AAPLAutoScrollDirectionRight
};

@interface AAPLCollectionViewGridLayout ()
@property (nonatomic) CGSize layoutSize;
@property (nonatomic) CGSize oldLayoutSize;
@property (nonatomic) BOOL preparingLayout;

/// Scroll direction isn't really supported, but it might be in the future. Always returns UICollectionViewScrollDirectionVertical.
@property (nonatomic, readonly) UICollectionViewScrollDirection scrollDirection;
@property (nonatomic) CGFloat scrollingSpeed;
@property (nonatomic) UIEdgeInsets scrollingTriggerEdgeInsets;
@property (strong, nonatomic) NSIndexPath *selectedItemIndexPath;
@property (strong, nonatomic) NSIndexPath *sourceItemIndexPath;
@property (strong, nonatomic) UIView *currentView;
@property (assign, nonatomic) CGPoint currentViewCenter;
@property (assign, nonatomic) CGPoint panTranslationInCollectionView;
@property (strong, nonatomic) CADisplayLink *displayLink;
@property (nonatomic) AAPLAutoScrollDirection autoscrollDirection;
@property (nonatomic) CGRect autoscrollBounds;
@property (nonatomic) CGRect dragBounds;
@property (nonatomic) CGSize dragCellSize;

@property (nonatomic, strong) NSMutableArray *layoutAttributes;
@property (nonatomic, copy) NSArray *sections;
@property (nonatomic) AAPLGridLayoutSectionInfo *globalSection;

@property (nonatomic) AAPLCollectionViewGridLayoutAttributes *globalSectionBackground;
@property (nonatomic, copy) NSArray *nonPinnableGlobalAttributes;

@property (nonatomic, strong) NSMutableDictionary *indexPathKindToSupplementaryAttributes;
@property (nonatomic, strong) NSMutableDictionary *oldIndexPathKindToSupplementaryAttributes;
@property (nonatomic, strong) NSMutableDictionary *indexPathKindToDecorationAttributes;
@property (nonatomic, strong) NSMutableDictionary *oldIndexPathKindToDecorationAttributes;
@property (nonatomic, strong) NSMutableDictionary *indexPathToItemAttributes;
@property (nonatomic, strong) NSMutableDictionary *oldIndexPathToItemAttributes;

/// A dictionary mapping the section index to the AAPLDataSourceSectionOperationDirection value
@property (nonatomic, strong) NSMutableDictionary *updateSectionDirections;
@property (nonatomic, strong) NSMutableSet *insertedIndexPaths;
@property (nonatomic, strong) NSMutableSet *removedIndexPaths;
@property (nonatomic, strong) NSMutableIndexSet *insertedSections;
@property (nonatomic, strong) NSMutableIndexSet *removedSections;
@property (nonatomic, strong) NSMutableIndexSet *reloadedSections;
@property (nonatomic) CGPoint contentOffsetDelta;
@end

@implementation AAPLCollectionViewGridLayout  {
    struct {
        /// the data source has the can edit method
        unsigned int dataSourceHasCanEdit:1;
        /// the data source has the can move method
        unsigned int dataSourceHasCanMoveItem:1;
        /// the data source has the can move item to index path method
        unsigned int dataSourceHasCanMoveItemToIndex:1;
        /// the data source has the move item to index path method
        unsigned int dataSourceHasMoveItemToIndex:1;
        /// the data source has the snapshot metrics method
        unsigned int dataSourceHasSnapshotMetrics:1;
        /// layout data becomes invalid if the data source changes
        unsigned int layoutDataIsValid:1;
        /// layout metrics will only be valid if layout data is also valid
        unsigned int layoutMetricsAreValid:1;
        /// contentOffset of collection view is valid
        unsigned int useCollectionViewContentOffset:1;
    } _flags;
}

- (instancetype)init
{
    self = [super init];
    if (!self)
        return nil;

    [self aapl_commonInitCollectionViewGridLayout];
    return self;
}

- (id)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;

    [self aapl_commonInitCollectionViewGridLayout];
    return self;
}

- (void)aapl_commonInitCollectionViewGridLayout
{
    [self registerClass:AAPLGridLayoutColorView.class forDecorationViewOfKind:AAPLGridLayoutRowSeparatorKind];
    [self registerClass:AAPLGridLayoutColorView.class forDecorationViewOfKind:AAPLGridLayoutColumnSeparatorKind];
    [self registerClass:AAPLGridLayoutColorView.class forDecorationViewOfKind:AAPLGridLayoutHeaderSeparatorKind];
    [self registerClass:AAPLGridLayoutColorView.class forDecorationViewOfKind:AAPLGridLayoutFooterSeparatorKind];
    [self registerClass:AAPLGridLayoutColorView.class forDecorationViewOfKind:AAPLGridLayoutGlobalHeaderBackgroundKind];

    _indexPathKindToDecorationAttributes = [NSMutableDictionary dictionary];
    _oldIndexPathKindToDecorationAttributes = [NSMutableDictionary dictionary];
    _indexPathToItemAttributes = [NSMutableDictionary dictionary];
    _oldIndexPathToItemAttributes = [NSMutableDictionary dictionary];
    _indexPathKindToSupplementaryAttributes = [NSMutableDictionary dictionary];
    _oldIndexPathKindToSupplementaryAttributes = [NSMutableDictionary dictionary];

    _scrollingTriggerEdgeInsets = UIEdgeInsetsMake(100, 100, 100, 100);

    _updateSectionDirections = [NSMutableDictionary dictionary];
    _layoutAttributes = [NSMutableArray array];
}


#pragma mark - Properties

- (void)setEditing:(BOOL)editing
{
    if (editing == _editing)
        return;

    _editing = editing;
    [self invalidateLayout];
}

#pragma mark - Drag & Drop

- (void)beginDraggingItemAtIndexPath:(NSIndexPath *)indexPath
{
    UICollectionView *collectionView = self.collectionView;
    UICollectionViewCell *cell = [collectionView cellForItemAtIndexPath:indexPath];

    CGRect dragFrame = cell.frame;
    _dragCellSize = dragFrame.size;

    UIView *snapshotView = [cell snapshotViewAfterScreenUpdates:YES];

    UIImageView *shadowView = [[UIImageView alloc] initWithFrame:CGRectInset(dragFrame, 0, -DRAG_SHADOW_HEIGHT)];
    shadowView.image = [[UIImage imageNamed:@"AAPLDragShadow"] resizableImageWithCapInsets:UIEdgeInsetsMake(DRAG_SHADOW_HEIGHT, 1, DRAG_SHADOW_HEIGHT, 1)];
    shadowView.opaque = NO;
    
    dragFrame.origin = CGPointMake(0, DRAG_SHADOW_HEIGHT);
    snapshotView.frame = dragFrame;
    [shadowView addSubview:snapshotView];
    _currentView = shadowView;

    _currentView.center = cell.center;
    [collectionView addSubview:_currentView];

    _currentViewCenter = _currentView.center;
    _selectedItemIndexPath = indexPath;
    _sourceItemIndexPath = indexPath;

    AAPLGridLayoutSectionInfo *sectionInfo = [self sectionInfoForIndexPath:indexPath];
    AAPLGridLayoutItemInfo *itemInfo = sectionInfo.items[indexPath.item];
    itemInfo.dragging = YES;

    _autoscrollBounds = CGRectZero;
    _autoscrollBounds.size = collectionView.frame.size;
    _autoscrollBounds = UIEdgeInsetsInsetRect(_autoscrollBounds, _scrollingTriggerEdgeInsets);

    CGRect collectionViewFrame = collectionView.frame;
    CGFloat collectionViewWidth = CGRectGetWidth(collectionViewFrame);
    CGFloat collectionViewHeight = CGRectGetHeight(collectionViewFrame);

    _dragBounds = CGRectMake(_dragCellSize.width/2, _dragCellSize.height/2, collectionViewWidth - _dragCellSize.width, collectionViewHeight - _dragCellSize.height);
}

- (void)cancelDragging
{
    [_currentView removeFromSuperview];

    AAPLGridLayoutSectionInfo *sourceSection = [self sectionInfoForIndexPath:_sourceItemIndexPath];
    AAPLGridLayoutSectionInfo *destinationSection = [self sectionInfoForIndexPath:_selectedItemIndexPath];

    destinationSection.phantomCellIndex = NSNotFound;
    destinationSection.phantomCellSize = CGSizeZero;

    NSInteger fromIndex = _sourceItemIndexPath.item;

    AAPLGridLayoutItemInfo *item = sourceSection.items[fromIndex];
    item.dragging = NO;

    AAPLGridLayoutInvalidationContext *context = [[AAPLGridLayoutInvalidationContext alloc] init];
    context.invalidateLayoutMetrics = YES;
    [self invalidateLayoutWithContext:context];
}

- (void)endDragging
{
    [_currentView removeFromSuperview];

    AAPLGridLayoutSectionInfo *sourceSection = [self sectionInfoForIndexPath:_sourceItemIndexPath];
    AAPLGridLayoutSectionInfo *destinationSection = [self sectionInfoForIndexPath:_selectedItemIndexPath];

    destinationSection.phantomCellIndex = NSNotFound;
    destinationSection.phantomCellSize = CGSizeZero;

    NSIndexPath *fromIndexPath = _sourceItemIndexPath;
    NSIndexPath *toIndexPath = _selectedItemIndexPath;

    NSInteger fromIndex = fromIndexPath.item;
    NSInteger toIndex = toIndexPath.item;

    AAPLGridLayoutItemInfo *item = sourceSection.items[fromIndex];
    item.dragging = NO;

    BOOL needsUpdate = YES;

    if (sourceSection == destinationSection) {
        if (fromIndex == toIndex)
            needsUpdate = NO;

        if (fromIndex < toIndex) {
            toIndex--;
            toIndexPath = [NSIndexPath indexPathForItem:toIndex inSection:toIndexPath.section];
        }
    }

    if (needsUpdate) {
        [sourceSection.items removeObjectAtIndex:fromIndex];
        [destinationSection.items insertObject:item atIndex:toIndex];

        if (_flags.dataSourceHasMoveItemToIndex) {
            UICollectionView *collectionView = self.collectionView;
            id<AAPLCollectionViewDataSourceGridLayout> dataSource = (id)collectionView.dataSource;

            // Tell the data source, but don't animate because we've already updated everything in place.
            [UIView performWithoutAnimation:^{
                [dataSource collectionView:collectionView moveItemAtIndexPath:fromIndexPath toIndexPath:toIndexPath];
            }];
        }
    }

    AAPLGridLayoutInvalidationContext *context = [[AAPLGridLayoutInvalidationContext alloc] init];
    context.invalidateLayoutMetrics = YES;
    [self invalidateLayoutWithContext:context];

    _selectedItemIndexPath = nil;
}

- (UICollectionViewScrollDirection)scrollDirection
{
    return UICollectionViewScrollDirectionVertical;
}

- (void)invalidateScrollTimer
{
    if (!_displayLink.paused)
        [_displayLink invalidate];
    _displayLink = nil;
}

- (void)setupScrollTimerInDirection:(AAPLAutoScrollDirection)direction {
    if (_displayLink && !_displayLink.paused) {
        if (_autoscrollDirection == direction)
            return;
    }

    [self invalidateScrollTimer];

    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleScroll:)];
    _autoscrollDirection = direction;

    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

// Tight loop, allocate memory sparely, even if they are stack allocation.
- (void)handleScroll:(CADisplayLink *)displayLink
{
    AAPLAutoScrollDirection direction = _autoscrollDirection;
    if (direction == AAPLAutoScrollDirectionUnknown)
        return;

    UICollectionView *collectionView = self.collectionView;
    CGSize frameSize = collectionView.bounds.size;
    CGSize contentSize = collectionView.contentSize;
    CGPoint contentOffset = collectionView.contentOffset;

    // Need to keep the distance as an integer, because the contentOffset property is automatically rounded. This would cause the view center to begin to diverge from the scrolling and appear to slip away from under the user's finger.
    CGFloat distance = AAPLRound(self.scrollingSpeed / FRAMES_PER_SECOND, collectionView.aapl_scale, NSRoundBankers);
    CGPoint translation = CGPointZero;

    switch (direction) {
        case AAPLAutoScrollDirectionUp: {
            distance = -distance;
            CGFloat minY = 0.0f;

            if ((contentOffset.y + distance) <= minY) {
                distance = -contentOffset.y;
            }

            translation = CGPointMake(0.0f, distance);
            break;
        }

        case AAPLAutoScrollDirectionDown: {
            CGFloat maxY = fmax(contentSize.height, frameSize.height) - frameSize.height;

            if ((contentOffset.y + distance) >= maxY) {
                distance = maxY - contentOffset.y;
            }

            translation = CGPointMake(0.0f, distance);
            break;
        }

        case AAPLAutoScrollDirectionLeft: {
            distance = -distance;
            CGFloat minX = 0.0f;

            if ((contentOffset.x + distance) <= minX) {
                distance = -contentOffset.x;
            }

            translation = CGPointMake(distance, 0.0f);
            break;
        }

        case AAPLAutoScrollDirectionRight: {
            CGFloat maxX = fmax(contentSize.width, frameSize.width) - frameSize.width;

            if ((contentOffset.x + distance) >= maxX) {
                distance = maxX - contentOffset.x;
            }

            translation = CGPointMake(distance, 0.0f);
            break;
        }

        default:
            break;
    }

    _currentViewCenter = AAPLPointAddPoint(_currentViewCenter, translation);
    _currentView.center = [self pointConstrainedToDragBounds:AAPLPointAddPoint(_currentViewCenter, _panTranslationInCollectionView)];
    collectionView.contentOffset = AAPLPointAddPoint(contentOffset, translation);
}

- (void)makeSpaceForDraggedCell
{
    NSIndexPath *newIndexPath = [self.collectionView indexPathForItemAtPoint:self.currentView.center];
    NSIndexPath *previousIndexPath = self.selectedItemIndexPath;

    AAPLGridLayoutSectionInfo *oldSection = [self sectionInfoForIndexPath:previousIndexPath];
    AAPLGridLayoutSectionInfo *newSection = [self sectionInfoForIndexPath:newIndexPath];

    if (!newIndexPath)
        return;

    // If I've already made space for the cell, all indexes in that section need to be incremented by 1
    if (oldSection.phantomCellIndex == previousIndexPath.item && newIndexPath.section == previousIndexPath.section && newIndexPath.item >= oldSection.phantomCellIndex)
        newIndexPath = [NSIndexPath indexPathForItem:newIndexPath.item+1 inSection:newIndexPath.section];

    if ([newIndexPath isEqual:previousIndexPath])
        return;

    UICollectionView *collectionView = self.collectionView;
    id<AAPLCollectionViewDataSourceGridLayout> dataSource = (id)collectionView.dataSource;

    if (!_flags.dataSourceHasCanMoveItemToIndex || ![dataSource collectionView:collectionView canMoveItemAtIndexPath:_sourceItemIndexPath toIndexPath:newIndexPath]) {
        return;
    }

    oldSection.phantomCellIndex = NSNotFound;
    oldSection.phantomCellSize = CGSizeZero;
    newSection.phantomCellIndex = newIndexPath.item;
    newSection.phantomCellSize = _dragCellSize;
    _selectedItemIndexPath = newIndexPath;

    AAPLGridLayoutInvalidationContext *context = [[AAPLGridLayoutInvalidationContext alloc] init];
    context.invalidateLayoutMetrics = YES;
    [self invalidateLayoutWithContext:context];
}

- (CGPoint)pointConstrainedToDragBounds:(CGPoint)viewCenter
{
    if (UICollectionViewScrollDirectionVertical == self.scrollDirection) {
        CGFloat left = CGRectGetMinX(_dragBounds);
        CGFloat right = CGRectGetMaxX(_dragBounds);
        if (viewCenter.x < left)
            viewCenter.x = left;
        else if (viewCenter.x > right)
            viewCenter.x = right;
    }

    return viewCenter;
}

- (void)handlePanGesture:(UIPanGestureRecognizer *)gestureRecognizer
{
    UICollectionView *collectionView = self.collectionView;
    CGPoint contentOffset = collectionView.contentOffset;

    switch (gestureRecognizer.state) {
        case UIGestureRecognizerStateBegan:

        case UIGestureRecognizerStateChanged: {
            self.panTranslationInCollectionView = [gestureRecognizer translationInView:collectionView];
            CGPoint viewCenter = AAPLPointAddPoint(self.currentViewCenter, self.panTranslationInCollectionView);

            self.currentView.center = [self pointConstrainedToDragBounds:viewCenter];

            [self makeSpaceForDraggedCell];

            CGPoint location = [gestureRecognizer locationInView:collectionView];

            switch (self.scrollDirection) {
                case UICollectionViewScrollDirectionVertical: {
                    CGFloat y = location.y - contentOffset.y;
                    CGFloat top = CGRectGetMinY(_autoscrollBounds);
                    CGFloat bottom = CGRectGetMaxY(_autoscrollBounds);

                    if (y < top) {
                        self.scrollingSpeed = 300 * ((top - y) / _scrollingTriggerEdgeInsets.top) * SCROLL_SPEED_MAX_MULTIPLIER;
                        [self setupScrollTimerInDirection:AAPLAutoScrollDirectionUp];
                    }
                    else if (y > bottom) {
                        self.scrollingSpeed = 300 * ((y - bottom) / _scrollingTriggerEdgeInsets.bottom) * SCROLL_SPEED_MAX_MULTIPLIER;
                        [self setupScrollTimerInDirection:AAPLAutoScrollDirectionDown];
                    }
                    else
                        [self invalidateScrollTimer];
                    break;
                }

                case UICollectionViewScrollDirectionHorizontal: {
                    CGFloat x = location.x - contentOffset.x;
                    CGFloat left = CGRectGetMinX(_autoscrollBounds);
                    CGFloat right = CGRectGetMaxX(_autoscrollBounds);

                    if (viewCenter.x < left) {
                        self.scrollingSpeed = 300 * ((left - x) / _scrollingTriggerEdgeInsets.left) * SCROLL_SPEED_MAX_MULTIPLIER;
                        [self setupScrollTimerInDirection:AAPLAutoScrollDirectionLeft];
                    }
                    else if (viewCenter.x > right) {
                        self.scrollingSpeed = 300 * ((x - right) / _scrollingTriggerEdgeInsets.right) * SCROLL_SPEED_MAX_MULTIPLIER;
                        [self setupScrollTimerInDirection:AAPLAutoScrollDirectionRight];
                    }
                    else
                        [self invalidateScrollTimer];
                    break;
                }
            }
            break;
        }

        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateEnded: {
            [self invalidateScrollTimer];
            break;
        }
            
        default:
            break;
    }
}


#pragma mark - UICollectionViewLayout API

+ (Class)layoutAttributesClass
{
    return [AAPLCollectionViewGridLayoutAttributes class];
}

+ (Class)invalidationContextClass
{
    return [AAPLGridLayoutInvalidationContext class];
}

- (void)invalidateLayoutWithContext:(AAPLGridLayoutInvalidationContext *)context
{
    NSParameterAssert([context isKindOfClass:[AAPLGridLayoutInvalidationContext class]]);

    BOOL invalidateDataSourceCounts = context.invalidateDataSourceCounts;
    BOOL invalidateEverything = context.invalidateEverything;
    BOOL invalidateLayoutMetrics = context.invalidateLayoutMetrics;

    _flags.useCollectionViewContentOffset = context.invalidateLayoutOrigin;

    if (invalidateEverything) {
        _flags.layoutMetricsAreValid = NO;
        _flags.layoutDataIsValid = NO;
    }

    if (_flags.layoutDataIsValid) {
        _flags.layoutMetricsAreValid = !(invalidateDataSourceCounts || invalidateLayoutMetrics);

        if (invalidateDataSourceCounts)
            _flags.layoutDataIsValid = NO;
    }
    LAYOUT_LOG(@"LayoutDataIsValid = %@ LayoutMetricsAreValid = %@", (_flags.layoutDataIsValid ? @"YES" : @"NO"), (_flags.layoutMetricsAreValid ? @"YES" : @"NO"));

    [super invalidateLayoutWithContext:context];
}

- (void)prepareLayout
{
    LAYOUT_TRACE();
    LAYOUT_LOG(@"bounds=%@", NSStringFromCGRect(self.collectionView.bounds));
    if (!self.collectionView.window)
        _flags.layoutMetricsAreValid = _flags.layoutDataIsValid = NO;

    if (!CGRectIsEmpty(self.collectionView.bounds)) {
        [self buildLayout];
    }
    
    [super prepareLayout];
}

- (NSArray *)layoutAttributesForElementsInRect:(CGRect)rect
{
    LAYOUT_TRACE();

    NSMutableArray *result = [NSMutableArray array];

    [self filterSpecialAttributes];

    for (AAPLCollectionViewGridLayoutAttributes *attributes in _layoutAttributes) {
        if (CGRectIntersectsRect(attributes.frame, rect))
            [result addObject:attributes];
    }

#if LAYOUT_DEBUGGING
    LAYOUT_LOG(@"rect=%@", NSStringFromCGRect(rect));
    for (AAPLCollectionViewGridLayoutAttributes *attr in result) {
        NSString *type;
        switch (attr.representedElementCategory) {
            case UICollectionElementCategoryCell:
                type = @"CELL";
                break;
            case UICollectionElementCategoryDecorationView:
                type = @"DECORATION";
                break;
            case UICollectionElementCategorySupplementaryView:
                type = @"SUPPLEMENTARY";
                break;
        }
        LAYOUT_LOG(@"  %@ %@ indexPath=%@ frame=%@ hidden=%@", type, (attr.representedElementKind ?:@""), AAPLStringFromNSIndexPath(attr.indexPath), NSStringFromCGRect(attr.frame), AAPLStringFromBOOL(attr.hidden));
    }
#endif

    return result;
}

- (AAPLGridLayoutSectionInfo *)sectionInfoForIndexPath:(NSIndexPath *)indexPath
{
    NSUInteger section = globalIndexPathSection(indexPath);
    if (section == NSNotFound) {
        return self.globalSection;
    }
    return self.sections[section];
}

- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath
{
    LAYOUT_TRACE();

    AAPLCollectionViewGridLayoutAttributes *attributes = _indexPathToItemAttributes[indexPath];
    if (attributes) {
        LAYOUT_LOG(@"Found attributes for %@: %@", indexPath, NSStringFromCGRect(attributes.frame));
        return attributes;
    }
    
    AAPLGridLayoutSectionInfo *section = [self sectionInfoForIndexPath:indexPath];
    if (!section) { return nil; }
    
    NSUInteger itemIndex = globalIndexPathItem(indexPath);
    if (itemIndex >= section.items.count) { return nil; }
    AAPLGridLayoutItemInfo *item = section.items[itemIndex];

    UICollectionView *collectionView = self.collectionView;
    id<AAPLCollectionViewDataSourceGridLayout> dataSource = (id)collectionView.dataSource;
    if (![dataSource conformsToProtocol:@protocol(AAPLCollectionViewDataSourceGridLayout)]) {
        dataSource = nil;
    }
    
    attributes = [[self.class layoutAttributesClass] layoutAttributesForCellWithIndexPath:indexPath];

    // Drag & Drop
    attributes.hidden = item.dragging;

    // Need to be clever if we're still preparing the layout…
    if (_preparingLayout) {
        attributes.hidden = YES;
    }
    attributes.frame = item.frame;
    attributes.zIndex = DEFAULT_ZINDEX;
    attributes.backgroundColor = section.backgroundColor;
    attributes.selectedBackgroundColor = section.selectedBackgroundColor;
    attributes.editing = _editing ? [dataSource collectionView:collectionView canEditItemAtIndexPath:indexPath] : NO;
    attributes.movable = _editing ? [dataSource collectionView:collectionView canMoveItemAtIndexPath:indexPath] : NO;
    attributes.columnIndex = item.columnIndex;

    LAYOUT_LOG(@"Created attributes for %@: %@ hidden = %@ preparingLayout %@", AAPLStringFromNSIndexPath(indexPath), NSStringFromCGRect(attributes.frame), AAPLStringFromBOOL(attributes.hidden), AAPLStringFromBOOL(_preparingLayout));

    if (!_preparingLayout)
        _indexPathToItemAttributes[indexPath] = attributes;
    return attributes;
}

- (UICollectionViewLayoutAttributes *)layoutAttributesForSupplementaryViewOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath
{
    LAYOUT_TRACE();
    
    AAPLIndexPathKind *indexPathKind = [[AAPLIndexPathKind alloc] initWithIndexPath:indexPath kind:kind];
    AAPLCollectionViewGridLayoutAttributes *existingAttributes = _indexPathKindToSupplementaryAttributes[indexPathKind];
    if (existingAttributes) { return existingAttributes; }
    
    AAPLGridLayoutSectionInfo *section = [self sectionInfoForIndexPath:indexPath];
    NSUInteger itemIndex = globalIndexPathItem(indexPath);
    AAPLGridLayoutSupplementalItemInfo *supplementalItem = [section supplementalItemOfKind:kind atIndex:itemIndex];
    if (!supplementalItem) { return nil; }

    AAPLCollectionViewGridLayoutAttributes *attributes = [[self.class layoutAttributesClass] layoutAttributesForSupplementaryViewOfKind:kind withIndexPath:indexPath];

    // Need to be clever if we're still preparing the layout…
    if (_preparingLayout) {
        attributes.hidden = YES;
    }

    attributes.frame = supplementalItem.frame;
    attributes.zIndex = HEADER_ZINDEX;
    attributes.editing = _editing;
    attributes.padding = supplementalItem.padding;
    attributes.backgroundColor = supplementalItem.backgroundColor ? : section.backgroundColor;
    attributes.selectedBackgroundColor = section.selectedBackgroundColor;

    if (!_preparingLayout) {
        _indexPathKindToSupplementaryAttributes[indexPathKind] = attributes;
    }

    return attributes;
}

- (UICollectionViewLayoutAttributes *)layoutAttributesForDecorationViewOfKind:(NSString*)kind atIndexPath:(NSIndexPath *)indexPath
{
    LAYOUT_TRACE();

//    NSInteger sectionIndex = (indexPath.length == 1 ? AAPLGlobalSection : indexPath.section);
//    NSInteger itemIndex = (indexPath.length == 1 ? [indexPath indexAtPosition:0] : indexPath.item);

    AAPLIndexPathKind *indexPathKind = [[AAPLIndexPathKind alloc] initWithIndexPath:indexPath kind:kind];
    UICollectionViewLayoutAttributes *attributes = _indexPathKindToDecorationAttributes[indexPathKind];
    if (attributes)
        return attributes;

    // FIXME: don't know… but returning nil crashes.
    return nil;
}

- (BOOL)shouldInvalidateLayoutForBoundsChange:(CGRect)newBounds
{
    return YES;
}

- (UICollectionViewLayoutInvalidationContext *)invalidationContextForBoundsChange:(CGRect)newBounds
{
    CGRect bounds = self.collectionView.bounds;
    AAPLGridLayoutInvalidationContext *context = (AAPLGridLayoutInvalidationContext *)[super invalidationContextForBoundsChange:newBounds];

    context.invalidateLayoutOrigin = !CGPointEqualToPoint(newBounds.origin, bounds.origin);

    // Only recompute the layout if the actual width has changed.
    context.invalidateLayoutMetrics = (!_approxeq(CGRectGetWidth(newBounds), CGRectGetWidth(bounds)) || !_approxeq(CGRectGetMinX(newBounds), CGRectGetMinX(bounds)));
    return context;
}

- (CGPoint)targetContentOffsetForProposedContentOffset:(CGPoint)proposedContentOffset withScrollingVelocity:(CGPoint)velocity
{
    return proposedContentOffset;
}

- (CGPoint)targetContentOffsetForProposedContentOffset:(CGPoint)proposedContentOffset
{
    UICollectionView *collectionView = self.collectionView;
    UIEdgeInsets insets = collectionView.contentInset;
    CGPoint targetContentOffset = proposedContentOffset;
    targetContentOffset.y += insets.top;

    CGFloat availableHeight = CGRectGetHeight(UIEdgeInsetsInsetRect(collectionView.bounds, insets));
    targetContentOffset.y = fmin(targetContentOffset.y, fmax(0, _layoutSize.height - availableHeight));

    NSInteger firstInsertedIndex = [self.insertedSections firstIndex];
    if (NSNotFound != firstInsertedIndex && AAPLDataSourceSectionOperationDirectionNone != [self.updateSectionDirections[@(firstInsertedIndex)] integerValue]) {
        AAPLGridLayoutSectionInfo *globalSection = self.globalSection;
        CGFloat globalNonPinnableHeight = [self heightOfAttributes:self.nonPinnableGlobalAttributes];
        CGFloat globalPinnableHeight = CGRectGetHeight(globalSection.frame) - globalNonPinnableHeight;

        AAPLGridLayoutSectionInfo *sectionInfo = self.sections[firstInsertedIndex];
        CGFloat minY = CGRectGetMinY(sectionInfo.frame);
        if (targetContentOffset.y + globalPinnableHeight > minY) {
            // need to make the section visable
            targetContentOffset.y = fmax(globalNonPinnableHeight, minY - globalPinnableHeight);
        }
    }

    targetContentOffset.y -= insets.top;

    LAYOUT_LOG(@"proposedContentOffset: %@; layoutSize: %@; availableHeight: %g; targetContentOffset: %@", NSStringFromCGPoint(proposedContentOffset), NSStringFromCGSize(_layoutSize), availableHeight, NSStringFromCGPoint(targetContentOffset));
    return targetContentOffset;
}

- (CGSize)collectionViewContentSize
{
    LAYOUT_TRACE();
    return _preparingLayout ? _oldLayoutSize : _layoutSize;
}

- (void)prepareForCollectionViewUpdates:(NSArray *)updateItems
{
    LAYOUT_TRACE();
    self.insertedIndexPaths = [NSMutableSet set];
    self.removedIndexPaths = [NSMutableSet set];
    self.insertedSections = [NSMutableIndexSet indexSet];
    self.removedSections = [NSMutableIndexSet indexSet];
    self.reloadedSections = [NSMutableIndexSet indexSet];

    for (UICollectionViewUpdateItem *updateItem in updateItems) {
        if (UICollectionUpdateActionInsert == updateItem.updateAction) {
            NSIndexPath *indexPath = updateItem.indexPathAfterUpdate;
            if (NSNotFound == indexPath.item)
                [self.insertedSections addIndex:indexPath.section];
            else
                [self.insertedIndexPaths addObject:indexPath];
        }
        else if (UICollectionUpdateActionDelete == updateItem.updateAction) {
            NSIndexPath *indexPath = updateItem.indexPathBeforeUpdate;
            if (NSNotFound == indexPath.item)
                [self.removedSections addIndex:indexPath.section];
            else
                [self.removedIndexPaths addObject:indexPath];
        }
        else if (UICollectionUpdateActionReload == updateItem.updateAction) {
            NSIndexPath *indexPath = updateItem.indexPathAfterUpdate;
            if (NSNotFound == indexPath.item)
                [self.reloadedSections addIndex:indexPath.section];
        }
    }

    UICollectionView *collectionView = self.collectionView;
    CGPoint contentOffset = collectionView.contentOffset;

    CGPoint newContentOffset = [self targetContentOffsetForProposedContentOffset:contentOffset];
    self.contentOffsetDelta = CGPointMake(newContentOffset.x - contentOffset.x, newContentOffset.y - contentOffset.y);

    [super prepareForCollectionViewUpdates:updateItems];
}

- (void)finalizeCollectionViewUpdates
{
    LAYOUT_TRACE();
    self.insertedIndexPaths = nil;
    self.removedIndexPaths = nil;
    self.insertedSections = nil;
    self.removedSections = nil;
    self.reloadedSections = nil;
    [self.updateSectionDirections removeAllObjects];
    [super finalizeCollectionViewUpdates];
}

// These methods are called by collection view during an update block.
// Return an array of index paths to indicate views that the layout is deleting or inserting in response to the update.
//- (NSArray *)indexPathsToDeleteForSupplementaryViewOfKind:(NSString *)kind
//{
//}

// FIXME: <rdar://problem/16520988>
// This method is ACTUALLY called for supplementary views
- (NSArray *)indexPathsToDeleteForDecorationViewOfKind:(NSString *)kind
{
    NSMutableArray *result = [NSMutableArray array];

    // FIXME: <rdar://problem/16117605> Be smarter about updating the attributes on layout updates
    [_oldIndexPathKindToDecorationAttributes enumerateKeysAndObjectsUsingBlock:^(AAPLIndexPathKind *indexPathKind, AAPLCollectionViewGridLayoutAttributes *attributes, BOOL *stop) {
        if (![indexPathKind.kind isEqualToString:kind])
            return;
        // If we have a similar decoration view in the new attributes, skip it.
        if (self.indexPathKindToDecorationAttributes[indexPathKind])
            return;
        [result addObject:indexPathKind.indexPath];
    }];

    return result;
}


- (NSArray *)indexPathsToInsertForSupplementaryViewOfKind:(NSString *)kind
{
    LAYOUT_LOG(@"kind=%@", kind);
    return [super indexPathsToInsertForSupplementaryViewOfKind:kind];
}

//- (NSArray *)indexPathsToInsertForDecorationViewOfKind:(NSString *)kind
//{
//}

- (UICollectionViewLayoutAttributes *)initialLayoutAttributesForAppearingDecorationElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath
{
    LAYOUT_LOG(@"kind:%@ indexPath:%@", kind, indexPath);

    AAPLCollectionViewGridLayoutAttributes *result = nil;

    NSInteger section = (indexPath.length > 1 ? indexPath.section : AAPLGlobalSection);

    AAPLDataSourceSectionOperationDirection direction = [_updateSectionDirections[@(section)] intValue];
    if (AAPLDataSourceSectionOperationDirectionNone != direction) {
        AAPLIndexPathKind *indexPathKind = [[AAPLIndexPathKind alloc] initWithIndexPath:indexPath kind:kind];
        return [self initialLayoutAttributesForAttributes:[_indexPathKindToDecorationAttributes[indexPathKind] copy] slidingInFromDirection:direction];
    }

    BOOL inserted = [self.insertedSections containsIndex:section];
    BOOL reloaded = [self.reloadedSections containsIndex:section];

    AAPLIndexPathKind *indexPathKind = [[AAPLIndexPathKind alloc] initWithIndexPath:indexPath kind:kind];
    result = [_indexPathKindToDecorationAttributes[indexPathKind] copy];

    if (inserted)
        result.alpha = 0;

    if (reloaded) {
        if (!_oldIndexPathKindToDecorationAttributes[indexPathKind])
            result.alpha = 0;
    }

    return [self initialLayoutAttributesForAttributes:result];
}

- (UICollectionViewLayoutAttributes *)finalLayoutAttributesForDisappearingDecorationElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath
{
    LAYOUT_LOG(@"kind:%@ indexPath:%@", kind, indexPath);

    AAPLCollectionViewGridLayoutAttributes *result = nil;

    NSInteger section = (indexPath.length > 1 ? indexPath.section : AAPLGlobalSection);

    AAPLDataSourceSectionOperationDirection direction = [_updateSectionDirections[@(section)] intValue];
    if (AAPLDataSourceSectionOperationDirectionNone != direction) {
        AAPLIndexPathKind *indexPathKind = [[AAPLIndexPathKind alloc] initWithIndexPath:indexPath kind:kind];
        return [self finalLayoutAttributesForAttributes:[_oldIndexPathKindToDecorationAttributes[indexPathKind] copy] slidingAwayFromDirection:direction];
    }

    BOOL removed = [self.removedSections containsIndex:section];
    BOOL reloaded = [self.reloadedSections containsIndex:section];

    AAPLIndexPathKind *indexPathKind = [[AAPLIndexPathKind alloc] initWithIndexPath:indexPath kind:kind];
    result = [_oldIndexPathKindToDecorationAttributes[indexPathKind] copy];

    if (removed)
        result.alpha = 0;

    if (reloaded) {
        if (!_indexPathKindToDecorationAttributes[indexPathKind])
            result.alpha = 0;
    }

    return [self finalLayoutAttributesForAttributes:result];
}

- (UICollectionViewLayoutAttributes *)initialLayoutAttributesForAppearingSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath
{
    LAYOUT_LOG(@"kind:%@ indexPath:%@", kind, indexPath);

    AAPLCollectionViewGridLayoutAttributes *result = nil;

    NSInteger section = (indexPath.length > 1 ? indexPath.section : AAPLGlobalSection);

    AAPLDataSourceSectionOperationDirection direction = [_updateSectionDirections[@(section)] intValue];
    if (AAPLDataSourceSectionOperationDirectionNone != direction) {
        AAPLIndexPathKind *indexPathKind = [[AAPLIndexPathKind alloc] initWithIndexPath:indexPath kind:kind];
        result = [_indexPathKindToSupplementaryAttributes[indexPathKind] copy];
        if ([AAPLCollectionElementKindPlaceholder isEqualToString:kind]) {
            result.alpha = 0;
            return [self initialLayoutAttributesForAttributes:result];
        }

        return [self initialLayoutAttributesForAttributes:result slidingInFromDirection:direction];
    }

    BOOL inserted = [self.insertedSections containsIndex:section];
    BOOL reloaded = [self.reloadedSections containsIndex:section];

    AAPLIndexPathKind *indexPathKind = [[AAPLIndexPathKind alloc] initWithIndexPath:indexPath kind:kind];
    result = [_indexPathKindToSupplementaryAttributes[indexPathKind] copy];

    if (inserted) {
        result.alpha = 0;
        result = [self initialLayoutAttributesForAttributes:result];
    }
    else if (reloaded) {
        if (!_oldIndexPathKindToSupplementaryAttributes[indexPathKind])
            result.alpha = 0;
    }

    return result;
}

- (UICollectionViewLayoutAttributes *)finalLayoutAttributesForDisappearingSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath
{
    LAYOUT_LOG(@"kind:%@ indexPath:%@", kind, indexPath);

    AAPLCollectionViewGridLayoutAttributes *result = nil;

    NSInteger section = (indexPath.length > 1 ? indexPath.section : AAPLGlobalSection);

    AAPLDataSourceSectionOperationDirection direction = [_updateSectionDirections[@(section)] intValue];
    if (AAPLDataSourceSectionOperationDirectionNone != direction) {
        AAPLIndexPathKind *indexPathKind = [[AAPLIndexPathKind alloc] initWithIndexPath:indexPath kind:kind];
        result = [_oldIndexPathKindToSupplementaryAttributes[indexPathKind] copy];
        if ([AAPLCollectionElementKindPlaceholder isEqualToString:kind]) {
            result.alpha = 0;
            return [self finalLayoutAttributesForAttributes:result];
        }

        return [self finalLayoutAttributesForAttributes:result slidingAwayFromDirection:direction];
    }

    BOOL removed = [self.removedSections containsIndex:section];
    BOOL reloaded = [self.reloadedSections containsIndex:section];

    AAPLIndexPathKind *indexPathKind = [[AAPLIndexPathKind alloc] initWithIndexPath:indexPath kind:kind];
    result = [_oldIndexPathKindToSupplementaryAttributes[indexPathKind] copy];

    if (removed || reloaded)
        result.alpha = 0;

    return [self finalLayoutAttributesForAttributes:result];
}

- (UICollectionViewLayoutAttributes *)initialLayoutAttributesForAppearingItemAtIndexPath:(NSIndexPath *)indexPath
{
    LAYOUT_LOG(@"indexPath:%@", indexPath);

    AAPLCollectionViewGridLayoutAttributes *result = nil;

    NSInteger section = (indexPath.length > 1 ? indexPath.section : AAPLGlobalSection);

    AAPLDataSourceSectionOperationDirection direction = [_updateSectionDirections[@(section)] intValue];
    if (AAPLDataSourceSectionOperationDirectionNone != direction) {
        return [self initialLayoutAttributesForAttributes:[_indexPathToItemAttributes[indexPath] copy] slidingInFromDirection:direction];
    }

    BOOL inserted = [self.insertedSections containsIndex:section] || [self.insertedIndexPaths containsObject:indexPath];
    BOOL reloaded = [self.reloadedSections containsIndex:section];

    result = [_indexPathToItemAttributes[indexPath] copy];

    if (inserted)
        result.alpha = 0;

    if (reloaded) {
        if (!_oldIndexPathToItemAttributes[indexPath])
            result.alpha = 0;
    }

    return [self initialLayoutAttributesForAttributes:result];
}

- (UICollectionViewLayoutAttributes *)finalLayoutAttributesForDisappearingItemAtIndexPath:(NSIndexPath *)indexPath
{
    LAYOUT_LOG(@"indexPath:%@", indexPath);

    AAPLCollectionViewGridLayoutAttributes *result = nil;

    NSInteger section = (indexPath.length > 1 ? indexPath.section : AAPLGlobalSection);

    AAPLDataSourceSectionOperationDirection direction = [_updateSectionDirections[@(section)] intValue];
    if (AAPLDataSourceSectionOperationDirectionNone != direction) {
        return [self finalLayoutAttributesForAttributes:[_oldIndexPathToItemAttributes[indexPath] copy] slidingAwayFromDirection:direction];
    }

    BOOL removed = [self.removedIndexPaths containsObject:indexPath] || [self.removedSections containsIndex:section];
    BOOL reloaded = [self.reloadedSections containsIndex:section];

    result = [_oldIndexPathToItemAttributes[indexPath] copy];

    if (removed)
        result.alpha = 0;

    if (reloaded) {
        // There's no item at this index path, so cross fade
        if (!_indexPathToItemAttributes[indexPath])
            result.alpha = 0;
    }

    return [self finalLayoutAttributesForAttributes:result];
}


#pragma mark - helpers

- (NSString *)recursiveDescription
{
    NSMutableString *result = [NSMutableString string];
    [result appendString:[self description]];
    
    if (self.globalSection) {
        [result appendString:@"\n    global = @[\n"];
        [result appendFormat:@"        %@\n", [self.globalSection valueForKey:@"recursiveDescription"]];
        [result appendString:@"    ]"];
    }
    
    if ([_sections count]) {
        [result appendString:@"\n    sections = @[\n"];
        
        NSArray *descriptions = [_sections valueForKey:@"recursiveDescription"];
        [result appendFormat:@"        %@\n", [descriptions componentsJoinedByString:@"\n        "]];
        [result appendString:@"    ]"];
    }
    
    return result;
}

- (void)updateFlagsFromCollectionView
{
    id dataSource = self.collectionView.dataSource;
    _flags.dataSourceHasCanEdit = [dataSource respondsToSelector:@selector(collectionView:canEditItemAtIndexPath:)];
    _flags.dataSourceHasCanMoveItem = [dataSource respondsToSelector:@selector(collectionView:canMoveItemAtIndexPath:)];
    _flags.dataSourceHasCanMoveItemToIndex = [dataSource respondsToSelector:@selector(collectionView:canMoveItemAtIndexPath:toIndexPath:)];
    _flags.dataSourceHasMoveItemToIndex = [dataSource respondsToSelector:@selector(collectionView:moveItemAtIndexPath:toIndexPath:)];
    _flags.dataSourceHasSnapshotMetrics = [dataSource respondsToSelector:@selector(snapshotMetrics)];
}

- (NSDictionary *)snapshotMetrics
{
    if (!_flags.dataSourceHasSnapshotMetrics) { return nil; }
    id <AAPLCollectionViewDataSourceGridLayout> dataSource = (id <AAPLCollectionViewDataSourceGridLayout>)self.collectionView.dataSource;
    return [dataSource snapshotMetrics];
}

- (void)resetLayoutInfo
{
    self.sections = nil;
    self.globalSection = nil;
    self.globalSectionBackground = nil;

    NSMutableDictionary *tmp;

    tmp = _oldIndexPathKindToSupplementaryAttributes;
    _oldIndexPathKindToSupplementaryAttributes = _indexPathKindToSupplementaryAttributes;
    _indexPathKindToSupplementaryAttributes = tmp;
    [_indexPathKindToSupplementaryAttributes removeAllObjects];

    tmp = _oldIndexPathToItemAttributes;
    _oldIndexPathToItemAttributes = _indexPathToItemAttributes;
    _indexPathToItemAttributes = tmp;
    [_indexPathToItemAttributes removeAllObjects];

    tmp = _oldIndexPathKindToDecorationAttributes;
    _oldIndexPathKindToDecorationAttributes = _indexPathKindToDecorationAttributes;
    _indexPathKindToDecorationAttributes = tmp;
    [_indexPathKindToDecorationAttributes removeAllObjects];
}

- (void)createLayoutInfoFromDataSource
{
    LAYOUT_TRACE();

    [self resetLayoutInfo];

    UICollectionView *collectionView = self.collectionView;
    NSDictionary *layoutMetrics = [self snapshotMetrics];

    UIEdgeInsets contentInset = collectionView.contentInset;
    CGFloat height = CGRectGetHeight(collectionView.bounds) - contentInset.bottom - contentInset.top;

    NSInteger numberOfSections = [collectionView numberOfSections];
    
    static UIColor *(^const fromMetrics)(UIColor *) = ^UIColor *(UIColor *color){
        if ([color isEqual:UIColor.clearColor]) { return nil; }
        return color;
    };
    
    void(^buildSection)(AAPLGridLayoutSectionInfo *, AAPLLayoutSectionMetrics *, NSInteger) = ^(AAPLGridLayoutSectionInfo *section, AAPLLayoutSectionMetrics *metrics, NSInteger sectionIndex){
        section.backgroundColor = fromMetrics(metrics.backgroundColor);
        section.selectedBackgroundColor = fromMetrics(metrics.selectedBackgroundColor);
        section.separatorColor = fromMetrics(metrics.separatorColor);
        section.separatorInsets = metrics.separatorInsets;
        section.separators = metrics.separators;
        section.numberOfColumns = metrics.numberOfColumns ?: 1;
        section.cellLayoutOrder = metrics.cellLayoutOrder;
        section.insets = metrics.padding;
        
        for (AAPLLayoutSupplementaryMetrics *suplMetrics in metrics.supplementaryViews) {
            CGFloat itemHeight = suplMetrics.height;
            if (!itemHeight) {
                if ([suplMetrics.kind isEqual:UICollectionElementKindSectionFooter]) { continue; }
            }
            
            AAPLGridLayoutSupplementalItemInfo *supl = [section addSupplementalItemOfKind:suplMetrics.kind];
            supl.height = itemHeight;
            supl.hidden = suplMetrics.hidden;
            supl.padding = suplMetrics.padding;
            
            if ([suplMetrics.kind isEqual:UICollectionElementKindSectionHeader]) {
                supl.visibleWhileShowingPlaceholder = suplMetrics.visibleWhileShowingPlaceholder;
                supl.shouldPin = suplMetrics.shouldPin;
                supl.backgroundColor = suplMetrics.backgroundColor ? fromMetrics(suplMetrics.backgroundColor) : section.backgroundColor;
                supl.selectedBackgroundColor = suplMetrics.selectedBackgroundColor ? fromMetrics(suplMetrics.selectedBackgroundColor) : section.selectedBackgroundColor;
            } else {
                supl.backgroundColor = suplMetrics.backgroundColor;
                supl.selectedBackgroundColor = suplMetrics.selectedBackgroundColor;
            }
        }
        
        // A section can either have a placeholder or items. Arbitrarily deciding the placeholder takes precedence.
        if (metrics.hasPlaceholder) {
            AAPLGridLayoutSupplementalItemInfo *placeholder = [section addSupplementalItemOfKind:AAPLCollectionElementKindPlaceholder];
            placeholder.height = height;
            return;
        }
        
        if (sectionIndex > collectionView.numberOfSections) { return; }
        
        NSInteger count = [collectionView numberOfItemsInSection:sectionIndex];
        CGFloat rowHeight = metrics.rowHeight ?: AAPLRowHeightDefault;
        [section addItems:count height:rowHeight];
    };

    LAYOUT_LOG(@"numberOfSections = %ld", (long)numberOfSections);

    AAPLLayoutSectionMetrics *globalMetrics = layoutMetrics[@(AAPLGlobalSection)];
    if (globalMetrics) {
        AAPLGridLayoutSectionInfo *section = [[AAPLGridLayoutSectionInfo alloc] init];
        self.globalSection = section;
        buildSection(section, globalMetrics, AAPLGlobalSection);
    }
    
    NSMutableArray *sections = NSMutableArray.new;
    for (NSInteger sectionIndex = 0; sectionIndex < numberOfSections; ++sectionIndex) {
        AAPLGridLayoutSectionInfo *section = [[AAPLGridLayoutSectionInfo alloc] init];
        [sections addObject:section];
        
        AAPLLayoutSectionMetrics *metrics = layoutMetrics[@(sectionIndex)];
        buildSection(section, metrics, sectionIndex);
    }
    self.sections = sections;
}

- (void)invalidateLayoutForItemAtIndexPath:(NSIndexPath *)indexPath
{
    AAPLGridLayoutSectionInfo *sectionInfo = [self sectionInfoForIndexPath:indexPath];

    NSUInteger itemIndex = globalIndexPathItem(indexPath);
    AAPLGridLayoutItemInfo *itemInfo = sectionInfo.items[itemIndex];

    UICollectionView *collectionView = self.collectionView;

    // This call really only makes sense if the section has variable height rows…
    CGRect rect = itemInfo.frame;
    CGSize fittingSize = CGSizeMake(CGRectGetWidth(rect), UILayoutFittingExpandedSize.height);

    // This is really only going to work if it's an AAPLCollectionViewCell, but we'll pretend
    UICollectionViewCell *cell = [collectionView cellForItemAtIndexPath:indexPath];
    rect.size = [cell aapl_preferredLayoutSizeFittingSize:fittingSize];
    itemInfo.frame = rect;

    AAPLGridLayoutInvalidationContext *context = [[AAPLGridLayoutInvalidationContext alloc] init];
    context.invalidateLayoutMetrics = YES;
    [self invalidateLayoutWithContext:context];
}

- (void)invalidateLayoutForGlobalSection {
    self.globalSection = nil;

    AAPLGridLayoutInvalidationContext *context = AAPLGridLayoutInvalidationContext.new;
    context.invalidateLayoutMetrics = YES;
    [self invalidateLayoutWithContext:context];
}

- (void)addLayoutAttributesForSection:(AAPLGridLayoutSectionInfo *)section atIndex:(NSInteger)sectionIndex dataSource:(id <AAPLCollectionViewDataSourceGridLayout>)dataSource
{
    UICollectionView *collectionView = self.collectionView;
    Class attributeClass = self.class.layoutAttributesClass;

    BOOL globalSection = (AAPLGlobalSection == sectionIndex);

    NSIndexPath *(^itemIndexPath)(NSUInteger) = ^(NSUInteger idx){
        NSUInteger indexes[] = { sectionIndex, idx };
        return [NSIndexPath indexPathWithIndexes:indexes length:2];
    };
    
    NSIndexPath *(^supplementIndexPath)(NSUInteger) = ^(NSUInteger idx){
        if (globalSection) {
            return [NSIndexPath indexPathWithIndex:idx];
        }
        return itemIndexPath(idx);
    };

    AAPLSeparatorOption separators = section.separators;
    NSInteger numberOfItems = section.items.count;
    NSUInteger numberOfHeaders = section.headers.count;
    CGFloat hair = self.collectionView.aapl_hairline;
    NSInteger numberOfColumns = section.numberOfColumns;
    NSUInteger numberOfSections = collectionView.numberOfSections;
    
    AAPLCollectionViewGridLayoutAttributes *(^addSeparator)(NSIndexPath *, CGRect, CGRectEdge, NSString *, AAPLSeparatorOption) = ^AAPLCollectionViewGridLayoutAttributes *(NSIndexPath *indexPath, CGRect rect, CGRectEdge edge, NSString *kind, AAPLSeparatorOption bit){
        UIColor *color = section.separatorColor;
        if (!color || !(separators & bit)) { return nil; }
        
        CGRect frame = AAPLSeparatorRect(rect, edge, hair);
        AAPLCollectionViewGridLayoutAttributes *separatorAttributes = (AAPLCollectionViewGridLayoutAttributes *)[attributeClass layoutAttributesForDecorationViewOfKind:kind withIndexPath:indexPath];
        separatorAttributes.frame = frame;
        separatorAttributes.backgroundColor = color;
        separatorAttributes.zIndex = SEPARATOR_ZINDEX;
        [self.layoutAttributes addObject:separatorAttributes];
        
        AAPLIndexPathKind *indexPathKind = [[AAPLIndexPathKind alloc] initWithIndexPath:indexPath kind:kind];
        self.indexPathKindToDecorationAttributes[indexPathKind] = separatorAttributes;
        
        return separatorAttributes;
    };
    
    NSMutableArray *newNonPinnable = [NSMutableArray new];
    NSMutableArray *newPinnable = [NSMutableArray new];

    if (globalSection && section.backgroundColor) {
        // Add the background decoration attribute
        NSIndexPath *indexPath = supplementIndexPath(0);
        AAPLCollectionViewGridLayoutAttributes *backgroundAttribute = [attributeClass layoutAttributesForDecorationViewOfKind:AAPLGridLayoutGlobalHeaderBackgroundKind withIndexPath:indexPath];
        // This will be updated by -filterSpecialAttributes
        backgroundAttribute.frame = section.frame;
        backgroundAttribute.unpinnedY = section.frame.origin.y;
        backgroundAttribute.zIndex = DEFAULT_ZINDEX;
        backgroundAttribute.pinnedHeader = NO;
        backgroundAttribute.backgroundColor = section.backgroundColor;
        backgroundAttribute.hidden = NO;
        [_layoutAttributes addObject:backgroundAttribute];

        self.globalSectionBackground = backgroundAttribute;
        AAPLIndexPathKind *indexPathKind = [[AAPLIndexPathKind alloc] initWithIndexPath:indexPath kind:AAPLGridLayoutGlobalHeaderBackgroundKind];
        _indexPathKindToDecorationAttributes[indexPathKind] = backgroundAttribute;
    }
    

    [section.headers enumerateObjectsUsingBlock:^(AAPLGridLayoutSupplementalItemInfo *header, NSUInteger headerIndex, BOOL *stop) {
        CGRect headerFrame = header.frame;

        // ignore headers if there are no items and the header isn't a global header
        if (!numberOfItems && !header.visibleWhileShowingPlaceholder)
            return;

        if (!header.height || header.hidden)
            return;

        NSIndexPath *indexPath = supplementIndexPath(headerIndex);
        AAPLCollectionViewGridLayoutAttributes *headerAttribute = [attributeClass layoutAttributesForSupplementaryViewOfKind:UICollectionElementKindSectionHeader withIndexPath:indexPath];
        headerAttribute.frame = headerFrame;
        headerAttribute.unpinnedY = headerFrame.origin.y;
        headerAttribute.zIndex = HEADER_ZINDEX;
        headerAttribute.pinnedHeader = NO;
        headerAttribute.backgroundColor = header.backgroundColor ? : section.backgroundColor;
        headerAttribute.selectedBackgroundColor = header.selectedBackgroundColor;
        headerAttribute.padding = header.padding;
        headerAttribute.editing = self.editing;
        headerAttribute.hidden = NO;
        [self.layoutAttributes addObject:headerAttribute];

        if (header.shouldPin) {
            [newPinnable addObject:headerAttribute];
        } else {
            [newNonPinnable addObject:headerAttribute];
        }

        AAPLIndexPathKind *indexPathKind = [[AAPLIndexPathKind alloc] initWithIndexPath:indexPath kind:UICollectionElementKindSectionHeader];
        self.indexPathKindToSupplementaryAttributes[indexPathKind] = headerAttribute;

        // Separators after global headers, before regular headers
        if (headerIndex) { addSeparator(indexPath, headerFrame, CGRectMinYEdge, AAPLGridLayoutHeaderSeparatorKind, AAPLSeparatorOptionSupplements); }
    }];
    
    // Separator after non-global header
    if (numberOfHeaders || numberOfItems) {
        NSIndexPath *indexPath = supplementIndexPath(numberOfHeaders);
        
        AAPLSeparatorOption bit;
        CGRect frame = section.headersRect;
        if (!numberOfHeaders) {
            bit = AAPLSeparatorOptionBeforeSection;
        } else if (!numberOfItems) {
            bit = AAPLSeparatorOptionAfterSection;
        } else {
            bit = AAPLSeparatorOptionSupplements;
            frame = UIEdgeInsetsInsetRect(frame, section.groupPadding);
        }
        
        addSeparator(indexPath, frame, CGRectMaxYEdge, AAPLGridLayoutRowSeparatorKind, bit);
    }

    __block NSUInteger itemIndex = 0;
    [section.rows enumerateObjectsUsingBlock:^(AAPLGridLayoutRowInfo *row, NSUInteger rowIndex, BOOL *stop) {
        if (!row.items.count)
            return;

        CGRect rowFrame = row.frame;

        // If there's a separator, add it above the current row…
        if (rowIndex) {
            UIEdgeInsets insets = AAPLInsetsWithout(section.separatorInsets, UIRectEdgeTop | UIRectEdgeBottom);
            CGRect rect = UIEdgeInsetsInsetRect(rowFrame, insets);
            NSIndexPath *indexPath = itemIndexPath(rowIndex);
            addSeparator(indexPath, rect, CGRectMinYEdge, AAPLGridLayoutRowSeparatorKind, AAPLSeparatorOptionRows);
        }

        [row.items enumerateObjectsUsingBlock:^(AAPLGridLayoutItemInfo *item, NSUInteger idx, BOOL *stopB) {

            CGRect itemFrame = item.frame;
            NSInteger columnIndex = item.columnIndex;

            if (columnIndex != NSNotFound && numberOfColumns > 1 && columnIndex > 0) {
                UIEdgeInsets insets = AAPLInsetsWithout(section.separatorInsets, UIRectEdgeLeft | UIRectEdgeRight);
                CGRect rect = UIEdgeInsetsInsetRect(itemFrame, insets);
                NSIndexPath *indexPath = itemIndexPath(rowIndex * numberOfColumns + columnIndex);
                addSeparator(indexPath, rect, CGRectMinXEdge, AAPLGridLayoutColumnSeparatorKind, AAPLSeparatorOptionColumns);
            }

            NSIndexPath *indexPath = itemIndexPath(itemIndex++);
            AAPLCollectionViewGridLayoutAttributes *newAttribute = [attributeClass layoutAttributesForCellWithIndexPath:indexPath];
            newAttribute.frame = itemFrame;
            newAttribute.zIndex = DEFAULT_ZINDEX;
            newAttribute.backgroundColor = section.backgroundColor;
            newAttribute.selectedBackgroundColor = section.selectedBackgroundColor;
            newAttribute.editing = self.editing ? (self->_flags.dataSourceHasCanEdit ? [dataSource collectionView:collectionView canEditItemAtIndexPath:indexPath] : YES) : NO;
            newAttribute.movable = self.editing && self->_flags.dataSourceHasCanMoveItem ? [dataSource collectionView:collectionView canMoveItemAtIndexPath:indexPath] : NO;
            newAttribute.columnIndex = columnIndex;
            newAttribute.hidden = NO;

            // Drag & Drop
            newAttribute.hidden = item.dragging;

            [self.layoutAttributes addObject:newAttribute];

            self.indexPathToItemAttributes[indexPath] = newAttribute;
        }];
    }];

    [section enumerateNonHeaderSupplementsPassingTest:NULL usingBlock:^(AAPLGridLayoutSupplementalItemInfo *item, NSString *kind, NSUInteger idx) {
        CGRect frame = item.frame;
        if (CGRectIsEmpty(frame)) { return; }

        NSIndexPath *indexPath = supplementIndexPath(idx);
        AAPLCollectionViewGridLayoutAttributes *itemAttribute = (AAPLCollectionViewGridLayoutAttributes *)[attributeClass layoutAttributesForSupplementaryViewOfKind:kind withIndexPath:indexPath];
        itemAttribute.frame = frame;
        itemAttribute.backgroundColor = item.backgroundColor ?: section.backgroundColor;
        itemAttribute.selectedBackgroundColor = item.selectedBackgroundColor ?: section.selectedBackgroundColor;
        itemAttribute.padding = item.padding;
        [self.layoutAttributes addObject:itemAttribute];

        AAPLIndexPathKind *indexPathKind = [[AAPLIndexPathKind alloc] initWithIndexPath:indexPath kind:kind];
        self.indexPathKindToSupplementaryAttributes[indexPathKind] = itemAttribute;

        // Separator above footers
        if ([kind isEqual:UICollectionElementKindSectionFooter]) {
            addSeparator(indexPath, item.frame, CGRectMinYEdge, AAPLGridLayoutFooterSeparatorKind, AAPLSeparatorOptionSupplements);
        }
    }];
    
    // Add the section separator below this section provided it's not the last section (or if the section explicitly says to)
    if (!globalSection && numberOfItems) {
        NSIndexPath *indexPath = itemIndexPath(numberOfItems);
        AAPLSeparatorOption bit = (sectionIndex + 1 < numberOfSections) ? AAPLSeparatorOptionAfterSection : AAPLSeparatorOptionAfterLastSection;
        addSeparator(indexPath, section.frame, CGRectMaxYEdge, AAPLGridLayoutRowSeparatorKind, bit);
    }
    
    section.pinnableHeaderAttributes = newPinnable;
    if (globalSection) {
        self.nonPinnableGlobalAttributes = newNonPinnable;
    }
}

- (CGFloat)heightOfAttributes:(NSArray *)attributes
{
    if (![attributes count])
        return 0;

    CGFloat minY = CGFLOAT_MAX;
    CGFloat maxY = CGFLOAT_MIN;

    for (AAPLCollectionViewGridLayoutAttributes *attr in attributes) {
        minY = fmin(minY, CGRectGetMinY(attr.frame));
        maxY = fmax(maxY, CGRectGetMaxY(attr.frame));
    }

    return maxY - minY;
}

- (void)buildLayout
{
    if (_flags.layoutMetricsAreValid)
        return;

    if (_preparingLayout)
        return;

    _preparingLayout = YES;

    LAYOUT_TRACE();

    [self updateFlagsFromCollectionView];

    if (!_flags.layoutDataIsValid) {
        [self createLayoutInfoFromDataSource];
        _flags.layoutDataIsValid = YES;
    }

    UICollectionView *collectionView = self.collectionView;
    UIEdgeInsets contentInset = collectionView.contentInset;
    CGFloat contentOffsetY = collectionView.contentOffset.y + contentInset.top;;

    _oldLayoutSize = _layoutSize;
    _layoutSize = CGSizeZero;

    [self.layoutAttributes removeAllObjects];
    
    id<AAPLCollectionViewDataSourceGridLayout> dataSource = (id)collectionView.dataSource;
    if (![dataSource conformsToProtocol:@protocol(AAPLCollectionViewDataSourceGridLayout)]) {
        dataSource = nil;
    }
    
    const CGRect viewport = (CGRect){ CGPointZero, UIEdgeInsetsInsetRect(collectionView.bounds, contentInset).size };
    __block CGRect layoutRect = viewport;
    __block CGPoint max = CGPointMake(CGRectGetMaxX(layoutRect), 0);
    
    __block BOOL shouldInvalidate = NO;
    CGSize(^measureSupplementary)(NSString *, NSIndexPath *, CGSize) = ^(NSString *kind, NSIndexPath *indexPath, CGSize size){
        shouldInvalidate |= YES;
        return [dataSource collectionView:self.collectionView sizeFittingSize:size forSupplementaryElementOfKind:kind atIndexPath:indexPath];
    };

    CGFloat globalNonPinningHeight = 0;
    AAPLGridLayoutSectionInfo *globalSection = self.globalSection;
    if (globalSection) {
        max = [globalSection layoutSectionWithRect:layoutRect measureSupplement:^CGSize(NSString *kind, NSUInteger idx, CGSize size) {
            NSIndexPath *indexPath = [NSIndexPath indexPathWithIndex:idx];
            return measureSupplementary(kind, indexPath, size);
        } measureItem:NULL];
        
        [self addLayoutAttributesForSection:globalSection atIndex:AAPLGlobalSection dataSource:dataSource];
        globalNonPinningHeight = [self heightOfAttributes:self.nonPinnableGlobalAttributes];
    }
    
    [self.sections enumerateObjectsUsingBlock:^(AAPLGridLayoutSectionInfo *section, NSUInteger sectionIndex, BOOL *stop) {
        layoutRect.size.height = fmax(0, layoutRect.size.height - max.y + layoutRect.origin.y);
        layoutRect.origin.y = max.y;

        max = [section layoutSectionWithRect:layoutRect measureSupplement:^(NSString *kind, NSUInteger idx, CGSize size) {
            NSIndexPath *indexPath = [NSIndexPath indexPathForItem:idx inSection:sectionIndex];
            return measureSupplementary(kind, indexPath, size);
        } measureItem:^(NSUInteger idx, CGSize size) {
            NSIndexPath *indexPath = [NSIndexPath indexPathForItem:idx inSection:sectionIndex];
            return [dataSource collectionView:collectionView sizeFittingSize:size forItemAtIndexPath:indexPath];
        }];
        
        [self addLayoutAttributesForSection:section atIndex:sectionIndex dataSource:dataSource];
    }];

    CGFloat layoutHeight = max.y;

    if (contentOffsetY >= globalNonPinningHeight && layoutHeight - globalNonPinningHeight < CGRectGetHeight(viewport)) {
        layoutHeight = CGRectGetHeight(viewport) + globalNonPinningHeight;
    }

    _layoutSize = CGSizeMake(CGRectGetWidth(layoutRect), layoutHeight);

    [self filterSpecialAttributes];

    _flags.layoutMetricsAreValid = YES;
    _preparingLayout = NO;

#if LAYOUT_DEBUGGING
    NSLog(@"layout attributes");
    for (UICollectionViewLayoutAttributes *attr in _layoutAttributes) {
        NSString *type;
        switch (attr.representedElementCategory) {
            case UICollectionElementCategoryCell:
                type = @"CELL";
                break;
            case UICollectionElementCategoryDecorationView:
                type = @"DECORATION";
                break;
            case UICollectionElementCategorySupplementaryView:
                type = @"SUPPLEMENTARY";
                break;
        }
        NSLog(@"  %@ %@ indexPath=%@ frame=%@ hidden=%@", type, (attr.representedElementKind ?:@""), AAPLStringFromNSIndexPath(attr.indexPath), NSStringFromCGRect(attr.frame), AAPLStringFromBOOL(attr.hidden));
    }
#endif

    // If the headers change, we need to invalidate…
    if (shouldInvalidate)
        [self invalidateLayout];
}

- (void)resetPinnableAttributes:(NSArray *)pinnableAttributes
{
    for (AAPLCollectionViewGridLayoutAttributes *attributes in pinnableAttributes) {
        attributes.pinnedHeader = NO;
        CGRect frame = attributes.frame;
        frame.origin.y = attributes.unpinnedY;
        attributes.frame = frame;
    }
}

- (CGFloat)applyBottomPinningToAttributes:(NSArray *)attributes maxY:(CGFloat)maxY
{
    for (AAPLCollectionViewGridLayoutAttributes *attr in [attributes reverseObjectEnumerator]) {
        CGRect frame = attr.frame;
        if (CGRectGetMaxY(frame) < maxY) {
            frame.origin.y = maxY - CGRectGetHeight(frame);
            maxY = frame.origin.y;
        }
        attr.zIndex = PINNED_HEADER_ZINDEX;
        attr.frame = frame;
    }

    return maxY;
}

// pin the attributes starting at minY as long a they don't cross maxY and return the new minY
- (CGFloat)applyTopPinningToAttributes:(NSArray *)attributes minY:(CGFloat)minY
{
    for (AAPLCollectionViewGridLayoutAttributes *attr in attributes) {
        CGRect  attrFrame = attr.frame;
        if (attrFrame.origin.y  < minY) {
            attrFrame.origin.y = minY;
            minY = CGRectGetMaxY(attrFrame);    // we have a new pinning offset
        }
        attr.frame = attrFrame;
    }
    return minY;
}

- (void)finalizePinnedAttributes:(NSArray *)attributes zIndex:(NSInteger)zIndex
{
    [attributes enumerateObjectsUsingBlock:^(AAPLCollectionViewGridLayoutAttributes *attr, NSUInteger attrIndex, BOOL *stop) {
        attr.pinnedHeader = !_approxeq(CGRectGetMinY(attr.frame), attr.unpinnedY);
        attr.zIndex = zIndex - attrIndex - 1;
    }];
}

- (BOOL)sectionOverlappingYOffset:(CGFloat)yOffset
{
    NSUInteger foundIdx = [self.sections indexOfObjectWithOptions:NSEnumerationConcurrent passingTest:^BOOL(AAPLGridLayoutSectionInfo *sectionInfo, NSUInteger sectionIndex, BOOL *stop) {
        CGRect frame = sectionInfo.frame;
        return CGRectGetMinY(frame) <= yOffset && yOffset <= CGRectGetMaxY(frame);
    }];
    
    if (foundIdx == NSNotFound) { return nil; }
    
    return self.sections[foundIdx];
}

- (AAPLGridLayoutSectionInfo *)firstSectionOverlappingYOffset:(CGFloat)yOffset
{
    NSUInteger foundIdx = [self.sections indexOfObjectWithOptions:NSEnumerationConcurrent passingTest:^BOOL(AAPLGridLayoutSectionInfo *sectionInfo, NSUInteger sectionIndex, BOOL *stop) {
        CGRect frame = sectionInfo.frame;
        return CGRectGetMinY(frame) <= yOffset && yOffset <= CGRectGetMaxY(frame);
    }];
    
    if (foundIdx == NSNotFound) { return nil; }
    
    return self.sections[foundIdx];
}

- (void)filterSpecialAttributes
{
    UICollectionView *collectionView = self.collectionView;
    NSInteger numSections = [collectionView numberOfSections];

    if (numSections <= 0 || numSections == NSNotFound)  // bail if we have no sections
        return;

    CGPoint contentOffset;

    if (_flags.useCollectionViewContentOffset)
        contentOffset = collectionView.contentOffset;
    else
        contentOffset = [self targetContentOffsetForProposedContentOffset:collectionView.contentOffset];

    CGFloat pinnableY = contentOffset.y + collectionView.contentInset.top;
    CGFloat nonPinnableY = pinnableY;

    // Pin the headers as appropriate
    AAPLGridLayoutSectionInfo *section = self.globalSection;
    if (section.pinnableHeaderAttributes) {
        [self resetPinnableAttributes:section.pinnableHeaderAttributes];
        pinnableY = [self applyTopPinningToAttributes:section.pinnableHeaderAttributes minY:pinnableY];
        [self finalizePinnedAttributes:section.pinnableHeaderAttributes zIndex:PINNED_HEADER_ZINDEX];
    }
    
    [self resetPinnableAttributes:self.nonPinnableGlobalAttributes];
    nonPinnableY = [self applyBottomPinningToAttributes:self.nonPinnableGlobalAttributes maxY:nonPinnableY];
    [self finalizePinnedAttributes:self.nonPinnableGlobalAttributes zIndex:PINNED_HEADER_ZINDEX];

    if (self.globalSectionBackground) {
        CGRect frame = self.globalSectionBackground.frame;
        frame.origin.y = fmin(nonPinnableY, collectionView.bounds.origin.y);
        CGFloat bottomY = fmax(CGRectGetMaxY([[section.pinnableHeaderAttributes lastObject] frame]), CGRectGetMaxY([[self.nonPinnableGlobalAttributes lastObject] frame]));
        frame.size.height =  bottomY - frame.origin.y;
        self.globalSectionBackground.frame = frame;
    }
    
    __block BOOL foundSection = NO;
    BOOL(^overlaps)(AAPLGridLayoutSectionInfo *) = ^(AAPLGridLayoutSectionInfo *sectionInfo){
        CGRect frame = sectionInfo.frame;
        if (!foundSection && CGRectGetMinY(frame) <= pinnableY && pinnableY <= CGRectGetMaxY(frame)) {
            foundSection = YES;
            return YES;
        }
        return NO;
    };
    
    for (AAPLGridLayoutSectionInfo *sectionInfo in self.sections) {
        [self resetPinnableAttributes:sectionInfo.pinnableHeaderAttributes];
        
        if (overlaps(sectionInfo)) {
            [self applyTopPinningToAttributes:sectionInfo.pinnableHeaderAttributes minY:pinnableY];
            [self finalizePinnedAttributes:sectionInfo.pinnableHeaderAttributes zIndex:PINNED_HEADER_ZINDEX - 100];
        }
    }
}

- (AAPLCollectionViewGridLayoutAttributes *)initialLayoutAttributesForAttributes:(AAPLCollectionViewGridLayoutAttributes *)attributes
{
    attributes.frame = CGRectOffset(attributes.frame, -self.contentOffsetDelta.x, -self.contentOffsetDelta.y);;
    return attributes;
}

- (AAPLCollectionViewGridLayoutAttributes *)finalLayoutAttributesForAttributes:(AAPLCollectionViewGridLayoutAttributes *)attributes
{
    CGFloat deltaX = + self.contentOffsetDelta.x;
    CGFloat deltaY = + self.contentOffsetDelta.y;
    CGRect frame = attributes.frame;
    if (attributes.pinnedHeader) {
        CGFloat newY = fmax(attributes.unpinnedY, CGRectGetMinY(frame) + deltaY);
        frame.origin.y = newY;
        frame.origin.x += deltaX;
    }
    else
        frame = CGRectOffset(frame, deltaX, deltaY);

    attributes.frame = frame;
    return attributes;
}

- (AAPLCollectionViewGridLayoutAttributes *)initialLayoutAttributesForAttributes:(AAPLCollectionViewGridLayoutAttributes *)attributes slidingInFromDirection:(AAPLDataSourceSectionOperationDirection)direction
{
    CGRect frame = attributes.frame;
    CGRect cvBounds = self.collectionView.bounds;

    if (direction == AAPLDataSourceSectionOperationDirectionLeft)
        frame.origin.x -= cvBounds.size.width;
    else
        frame.origin.x += cvBounds.size.width;

    attributes.frame = frame;
    return [self initialLayoutAttributesForAttributes:attributes];
}

- (AAPLCollectionViewGridLayoutAttributes *)finalLayoutAttributesForAttributes:(AAPLCollectionViewGridLayoutAttributes *)attributes slidingAwayFromDirection:(AAPLDataSourceSectionOperationDirection)direction
{
    CGRect frame = attributes.frame;
    CGRect cvBounds = self.collectionView.bounds;
    if (direction == AAPLDataSourceSectionOperationDirectionLeft)
        frame.origin.x += cvBounds.size.width;
    else
        frame.origin.x -= cvBounds.size.width;

    attributes.alpha = 0;
    attributes.frame = CGRectOffset(frame, self.contentOffsetDelta.x, self.contentOffsetDelta.y);
    return attributes;
}

#pragma mark - AAPLDataSource delegate methods

- (void)dataSource:(AAPLDataSource *)dataSource didInsertSections:(NSIndexSet *)sections direction:(AAPLDataSourceSectionOperationDirection)direction
{
    [sections enumerateIndexesUsingBlock:^(NSUInteger sectionIndex, BOOL *stop) {
        self.updateSectionDirections[@(sectionIndex)] = @(direction);
    }];
}

- (void)dataSource:(AAPLDataSource *)dataSource didRemoveSections:(NSIndexSet *)sections direction:(AAPLDataSourceSectionOperationDirection)direction
{
    [sections enumerateIndexesUsingBlock:^(NSUInteger sectionIndex, BOOL *stop) {
        self.updateSectionDirections[@(sectionIndex)] = @(direction);
    }];
}

- (void)dataSource:(AAPLDataSource *)dataSource didMoveSection:(NSInteger)section toSection:(NSInteger)newSection direction:(AAPLDataSourceSectionOperationDirection)direction
{
    _updateSectionDirections[@(section)] = @(direction);
    _updateSectionDirections[@(newSection)] = @(direction);
}

@end
