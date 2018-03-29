/*
 * Contains an AVL implementation for Type Buckets
 */

 module gc.impl.typed.bucketavl;

 import gc.impl.typed.systemalloc;
 import gc.impl.typed.typebucket;

/**
 * Node describes a node in an AVL binary tree.
 *
 */
struct Node
{
    TypeBucket bucket;
    Node* left;
    Node* right;

    int height;
}

/**
 * The BucketAVL is an AVL Tree implementation intended for TypeBuckets.
 *
 */
struct BucketAVL
{
    ///helper function to get the max
    int max(int a, int b) nothrow
    {
        return (a>b)?a:b;
    }

    ///helper function to get the height of a node (because null)
    int getHeight(Node* node) nothrow
    {
        if(node is null)
            return 0;

        return node.height;
    }

    /// the root node
    Node* root;

    NodeStack stack;

    /// the boundaries of the heap managed by the buckets
    void* bottomBoundary = cast(void*)size_t.max, topBoundary = cast(void*)0;

    void insert(TypeBucket bucket) nothrow
    {
        if(root is null)
        {
            Node* node = cast(Node*)salloc(Node.sizeof);

            node.left = null;
            node.right = null;
            node.bucket = bucket;

            root = node;
            return;
        }

        insertHelper(root, bucket);

        if(bucket.memory < bottomBoundary)
            bottomBoundary = bucket.memory;

        if(bucket.memory > topBoundary) //buckets don't overlap, so this is fine
            topBoundary = bucket.memory + bucket.objectSize * bucket.numberOfObjects;

    }

    private void insertHelper(ref Node* current, TypeBucket bucket) nothrow
    {
        if( bucket.memory < current.bucket.memory)
        {
            if(current.left is null)
            {

                Node* node = cast(Node*)salloc(Node.sizeof);

                node.left = null;
                node.right = null;
                node.bucket = bucket;

                current.left = node;
                current.left.height = 1;
            }
            else
            {
                insertHelper(current.left, bucket);
            }
        }
        else //we will never have duplicates
        {
            if(current.right is null)
            {
                Node* node = cast(Node*)salloc(Node.sizeof);

                node.left = null;
                node.right = null;
                node.bucket = bucket;

                current.right = node;
                current.right.height = 1;
            }
            else
            {
                insertHelper(current.right, bucket);
            }
        }


        int leftHeight = getHeight(current.left);
        int rightHeight = getHeight(current.right);

        current.height = ((leftHeight>rightHeight)?leftHeight:rightHeight) + 1;

        int balance = leftHeight - rightHeight;

        if(balance > 1)
        {
            if(bucket.memory < current.left.bucket.memory)
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
            if(bucket.memory < current.right.bucket.memory)
            {
                //right left rotation
                current.right = LLRot(current.left);
                current = RRRot(current);
                return;
            }
            //right right rotation
            current = RRRot(current);
        }

    }

    ///Search the Binary tree for the bucket containing ptr
    TypeBucket findBucket(void* ptr) nothrow @nogc
    {
        //check if the pointer is in the boundaries of the heap memory
        //these might not be calculated correctly as sometimes ptr is valid
        //when ptr == topBoundary
        if(ptr < bottomBoundary || ptr > topBoundary)
            return null;

        Node* current = root;
        while(current !is null)
        {
            if(current.bucket.containsObject(ptr))
                return current.bucket;

            current = (ptr < current.bucket.memory)? current.left:current.right;
        }

        return null;
    }

    int opApply(int delegate(TypeBucket) nothrow dg) nothrow
    {
        int result = 0;
        Node* current = root;

        while(true)
        {
            while(current != null)
            {
                stack.push(current);
                current = current.left;
            }

            if(!stack.empty())
            {
                current = stack.pop();

                result = dg(current.bucket);

                if(result)
                    break;

                current = current.right;
                int breaker = 0;
            }
            else
                break;
        }



        return result;
    }

    Node* LLRot(Node* k2) nothrow
    {
        Node* k1 = k2.left;
        Node* y = k1.right;

        k2.left = y;
        k1.right = k2;

        //height updates
        k2.height = max(getHeight(k2.left), getHeight(k2.left)) + 1;
        k1.height = max(getHeight(k1.left), getHeight(k1.left)) + 1;

        return k1;
    }

    Node* RRRot(Node* k2) nothrow
    {
        Node* k1 = k2.right;
        Node* y = k1.left;

        k2.right = y;
        k1.left = k2;


        //height updates
        k2.height = max(getHeight(k2.left), getHeight(k2.left)) + 1;
        k1.height = max(getHeight(k1.left), getHeight(k1.left)) + 1;

        return k1;
    }

}

/**
 * NodeStack is a stack of binary tree nodes.
 *
 * This stack is used by the BucketAVL structure to implement some functions
 * iteratively.
 */
struct NodeStack
{
    ///The array used to implement the stack
    ///20 nodes should be plenty, even for a huge tree (log2 of 100000 is 16.6)
    private Node*[20] array;
    private ubyte count = 0;

    bool empty() nothrow
    {
        return count == 0;
    }

    void push(Node* node) nothrow
    {
        array[++count] = node;
    }

    Node* pop() nothrow
    {
        return  array[count--];
    }
}



