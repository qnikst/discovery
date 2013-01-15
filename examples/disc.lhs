> {-# LANGUAGE OverloadedStrings #-}

> import Network.Heartbeat
> import Data.Time.Clock

We have 2 approaches for service discovery:

\begin{itemize}
  \item OneWay. with one way service model each service broadcast his
      presence to the network. If clients wants to connect to server
      he just listenes on specified port.
  \item Reques-Reply. With RR model new client broadcast his precense
      to the network, and if server hears such a request he replies
      to the client.
\end{itemize}

Let's take a look at theese aproaches and API they give.
Here is simple broadcast server that it's name to the network
once per second.

> example1 name bcast port = do
>   discoveryServer (OneWay (secondsToDiffTime 1) (return name))
>                   bcast
>                   port

We can add a client in such network and listen for servers:

> example1client port = do
>  print =<< discoveryClient (OneWayC id) port (secondsToDiffTime 2)
 

We may want to send additional data e.g. a number of connections
so client can decide what server we want to use

> -- example2  name bast port = do
> --   box <- newTVarIO 0
> --   let nameNum = atomically (readTVar box) >>= \x -> return (name ++ "/" ++ show x)
> --   r <- discoveryServer (OneWay (secondsToDiffTime 1) Nothing (nameNum))
> --                  bcast
> --                  port
> --   return (box, r)

Now we have a box that we may want to update and so an updated 
information will be broadcasted over the network.

> -- example4 name bcast port = do
> --   discoveryServer (ReqReply (return name))
> --                  bcast
> --                  port


All previous examples we use a separate nodes and clients, and
now we want to build a dynamic network, that consist of many nodes.
Now we have an additional problem: heartbeating - we want to know
if node still alive and maybe perform some additional actions on 
node death and born.

We have 2 possibilities either use data connection protocol (so
it's not covered by this library) or use OneWay discovery

So we are introduce Heartbeat datatype, thats callback API to 
support 

> -- example5 name bcast port = do
> --   discovery (secondsToDiffTime 1)
> --            (HeartBeat



Simple main to run all examples:

> -- main = do 
> --    (type_:_) <- getArgs
> --   case type_ of
> --     "1" -> do broadcastServer1
