/*
 * Contains an AVL implementation for Type Buckets
 */

 module gc.impl.typed.bucketavl;

 import gc.impl.typed.systemalloc;
 import gc.impl.typed.typesystem;


     /**
     * SearchNode describes a node in a binary tree.
     *
     * This node is used when searching for a bucket by pointer.
     */
    struct SearchNode
    {
        TypeBucket* bucket;
        SearchNode* left;
        SearchNode* right;

        int height;
    }

    /// This is the root node in a binary tree
    SearchNode* root;

    ///insert a SearchNode into the binary tree
    void searchNodeInsert(SearchNode* node) nothrow
    {
        if(root is null)
        {
            root = node;
            return;
        }

        searchNodeInsertHelper(root, node);
        return;
    }


    void searchNodeInsertHelper(ref SearchNode* current, SearchNode* node) nothrow
    {
        if( node.bucket.memory < current.bucket.memory)
        {
            if(current.left is null)
            {
                current.left = node;
                current.left.height = 1;
            }
            else
            {
                searchNodeInsertHelper(current.left, node);
            }
        }
        else //we will never have duplicates
        {
            if(current.right is null)
            {
                current.right = node;
                current.right.height = 1;
            }
            else
            {
                searchNodeInsertHelper(current.right, node);
            }
        }


        int leftHeight = getHeight(current.left);
        int rightHeight = getHeight(current.right);

        current.height = ((leftHeight>rightHeight)?leftHeight:rightHeight) + 1;

        int balance = leftHeight - rightHeight;

        if(balance > 1)
        {
            if(node.bucket.memory < current.left.bucket.memory)
            {
                //left left rotation
                current = LLRot(current);
                return;
            }

            //left right rotation
            current.left  = RRRot(current.left);
            current = LLRot(current);
        }
        else if(balance < -1)
        {
            if(node.bucket.memory < current.right.bucket.memory)
            {
                //right left rotation
                current.right = LLRot(current.left);
                current = RRRot(current);
                return;
            }
            //right right rotation
            current = RRRot(current);
            int breaker = 0;
        }

    }

    SearchNode* LLRot(SearchNode* k2) nothrow
    {
        SearchNode* k1 = k2.left;
        SearchNode* y = k1.right;

        k2.left = y;
        k1.right = k2;

        //height updates
        k2.height = max(getHeight(k2.left), getHeight(k2.left)) + 1;
        k1.height = max(getHeight(k1.left), getHeight(k1.left)) + 1;

        int breaker = 0;

        return k1;
    }

    SearchNode* RRRot(SearchNode* k2) nothrow
    {
        SearchNode* k1 = k2.right;
        SearchNode* y = k1.left;

        k2.right = y;
        k1.left = k2;


        //height updates
        k2.height = max(getHeight(k2.left), getHeight(k2.left)) + 1;
        k1.height = max(getHeight(k1.left), getHeight(k1.left)) + 1;

        int breaker = 0;

        return k1;
    }

    int max(int a, int b) nothrow
    {
        return (a>b)?a:b;
    }

    int getHeight(SearchNode* node) nothrow
    {
        if(node is null)
            return 0;

        return node.height;
    }

    ///Search the Binary tree for the bucket containing ptr
    TypeBucket* findBucket(void* ptr) nothrow
    {
        //check if the pointer is in the boundaries of the heap memory
        if(ptr < heapBottom || ptr >= heapTop)
            return null;

        SearchNode* current = root;
        while(current !is null)
        {
            if(current.bucket.containsObject(ptr))
                return current.bucket;

            current = (ptr < current.bucket.memory)? current.left:current.right;
        }

        return null;
    }